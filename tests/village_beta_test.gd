extends SceneTree
## M5-05 "Village Beta" integration fixture.
##
## One real deployable authority (Game/world/world_server.gd) over loopback WSS,
## two member processes with distinct identities, and one parent orchestrator.
## It proves the friend-village loop end to end:
##   - both members join the same world and see each other in the roster;
##   - the owner grants one member harvest rights on one named field only, the
##     grantee is refused in a field the owner did not grant, the accepted
##     harvest carries the authority's `authorized` stamp, and revocation is
##     visible to the grantee without a reconnect;
##   - two members release a build for the same named yard slot at the same
##     moment: exactly one is committed and the world stores one record;
##   - a gift transfers one basket, replaying the same delivery id does not move
##     it twice, and the recipient's restored bag holds exactly the gift;
##   - the authority is stopped cleanly and restarted from the same save
##     directory; both members auto-reconnect within the client's backoff and
##     receive a fresh authoritative summary that still has the house, the bag,
##     the grant/revocation state and both roster rows;
##   - the ordinary member's summary is bounded and aggregate, and an ordinary
##     member who never steals and never joins an organisation can still load,
##     view and reconnect.
##
## Roles: parent (default) and member (--role=member --who=a|b). Members are
## separate processes because SceneMultiplayer is per SceneTree and both members
## must be online at once, including across the authority restart.
##
## Shared state stays under one unique .local/verification/village-beta-*/
## directory. The parent writes step-<who>-<n>.json; each member writes
## result-<who>-<n>.json and state-<who>.json atomically.

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const FarmState = preload("res://farm/farm_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const WORLD: String = "world-village"
const GRANT_ID: String = "server-invite"
const START: float = 1800000000.0

const A_ID: String = "player_00000000000000000000000000000041"
const A_NAME: String = "阿青"
const B_ID: String = "player_00000000000000000000000000000042"
const B_NAME: String = "小满"

## One named yard slot and one shared field. Both members attempt this slot.
const BUILD_SLOT: String = "yard_a"
const BUILD_BLUEPRINT: String = "cottage"
const BUILD_SECONDS: int = 600
const SOW_FIELD_GRANTED: String = "field_04"
const SOW_FIELD_PLAIN: String = "field_05"
const SOW_CELL: String = "cell_07"
const CROP: String = "greens"
const GREENS_DURATION: float = 1800.0
const HARVEST_FIELD: String = "field_03"
const HARVEST_CELL: String = "cell_06"

const STEP_TIMEOUT_MS: int = 20000
const MEMBER_LIFETIME: float = 150.0
## A bounded number of summary deliveries is normal (join, an explicit read,
## reconnect and the client's 30 s reconcile); a per-cell flood would not fit.
const MAX_SUMMARIES: int = 12
## The aggregate summary is one document. It may carry the bounded cell map but
## must not carry an event history or an unbounded reply.
const MAX_SUMMARY_BYTES: int = 262144
const MAX_SUMMARY_CELLS: int = 160

# ----------------------------------------------------------------- options

var role: String = "parent"
var who: String = ""
var dir: String = ""
var cert_file: String = ""
var invite_file: String = ""
var url: String = ""
var world: String = WORLD
var player_id: String = ""
var display_name: String = ""
var port: int = 0

# --------------------------------------------------------- parent state
var repo_root: String = ""
var world_dir: String = ""
var server_pid: int = -1
var member_pids: Dictionary = {}
var next_step: Dictionary = {}
var checks: int = 0
var failures: Array[String] = []

# --------------------------------------------------------- member state
var client: WorldClient
var fatal_reason: String = ""
var step_index: int = 0
var last_farm: FarmState = null
var last_now: float = 0.0
var state_ready_count: int = 0
var summary_count: int = 0
var catch_up_count: int = 0
var summary_metrics: Dictionary = {}
var changes_count: int = 0
var changes_without_command: int = 0
var reconnect_events: Array = []
var reconnected_sequences: Array = []
var refused_reasons: Array = []
var lost_reasons: Array = []
var roster_rows: Array = []
var social_actions: Array = []
var submitted_kinds: Array = []
var replies: Dictionary = {}
## Paths already observed as valid, so a later empty read is known to be the
## rename gap rather than "not written yet".
var _state_seen: Dictionary = {}
var social_results: Dictionary = {}
var busy: bool = false


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		elif argument.begins_with("--who="): who = argument.trim_prefix("--who=")
		elif argument.begins_with("--dir="): dir = argument.trim_prefix("--dir=")
		elif argument.begins_with("--cert-file="): cert_file = argument.trim_prefix("--cert-file=")
		elif argument.begins_with("--invite-file="): invite_file = argument.trim_prefix("--invite-file=")
		elif argument.begins_with("--url="): url = argument.trim_prefix("--url=")
		elif argument.begins_with("--world="): world = argument.trim_prefix("--world=")
		elif argument.begins_with("--player-id="): player_id = argument.trim_prefix("--player-id=")
		elif argument.begins_with("--name="): display_name = argument.trim_prefix("--name=")
		elif argument.begins_with("--port="): port = argument.trim_prefix("--port=").to_int()
	_run.call_deferred()


func _run() -> void:
	match role:
		"member": await _run_member()
		_: await _run_parent()


# ================================================================== parent

func _run_parent() -> void:
	repo_root = _repo()
	dir = repo_root.path_join(".local/verification/village-beta-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	_expect(DirAccess.dir_exists_absolute(dir), "An isolated verification directory is created")

	port = _free_port()
	_expect(port > 0, "A free loopback port is available")
	if port <= 0:
		await _shutdown()
		_finish()
		return

	# (1) The deployable authority, from the same entry m4_reconnect_test uses.
	server_pid = _start_server()
	_expect(server_pid > 0, "The authority process starts")
	_expect(server_pid > 0 and await _wait_status("running", 25000),
		"The authority serves the world")
	var material_ok: bool = FileAccess.file_exists(world_dir.path_join("invite.bin")) \
		and FileAccess.file_exists(world_dir.path_join("server.crt"))
	_expect(material_ok, "The authority published its invite and pinned certificate")
	if server_pid <= 0 or not material_ok:
		await _shutdown()
		_finish()
		return

	# (2) Two members, distinct identities, same reusable member invitation.
	member_pids["a"] = _start_member("a")
	member_pids["b"] = _start_member("b")
	_expect(int(member_pids.get("a", 0)) > 0, "Member A process starts")
	_expect(int(member_pids.get("b", 0)) > 0, "Member B process starts")

	_expect(await _wait_joined("a", 30000), "Member A joins the shared world")
	_expect(await _wait_joined("b", 30000), "Member B joins the shared world")
	_expect(await _wait_state_ready("a", 1, 20000), "Member A receives the authoritative summary")
	_expect(await _wait_state_ready("b", 1, 20000), "Member B receives the authoritative summary")
	_expect(await _wait_roster("a", 2, 20000) and await _wait_roster("b", 2, 20000),
		"Both members see a two-row neighbour roster")

	var a_join := _member_state("a")
	var b_join := _member_state("b")
	_expect(str(a_join.get("player_id", "")) == A_ID and str(b_join.get("player_id", "")) == B_ID,
		"Member A and member B joined with distinct identities")
	_expect(str(a_join.get("world_id", "")) == WORLD and str(b_join.get("world_id", "")) == WORLD,
		"Both members joined the same world identity")
	var roster_ids := _roster_ids(a_join)
	_expect(roster_ids.size() == 2 and roster_ids.has(A_ID) and roster_ids.has(B_ID),
		"The roster names both distinct players exactly once")

	# (3) Register both players in the social document, then sow two crops that
	# belong to A on two separate named fields.
	var reg_a := await _social("a", "reg-a", "state", {})
	var reg_b := await _social("b", "reg-b", "state", {})
	_expect(bool(reg_a.get("ok", false)), "Member A is registered in the social document")
	_expect(bool(reg_b.get("ok", false)), "Member B is registered in the social document")

	var clock := await _summary("a")
	_expect(bool(clock.get("ok", false)), "Member A refreshes its authoritative clock before sowing")

	var sow_shared := await _submit_now("a", "sow-shared", {
		"id": "vb-sow-shared", "kind": "sow", "field_id": SOW_FIELD_GRANTED,
		"cell_id": SOW_CELL, "crop_id": CROP})
	_expect(bool(sow_shared.get("ok", false)), "A sows a crop on the field it will share")
	var sow_plain := await _submit_now("a", "sow-plain", {
		"id": "vb-sow-plain", "kind": "sow", "field_id": SOW_FIELD_PLAIN,
		"cell_id": SOW_CELL, "crop_id": CROP})
	_expect(bool(sow_plain.get("ok", false)), "A sows a second crop on a field it will not share")
	var sow_sequence: int = int(_payload_of(sow_plain).get("sequence", -1))
	_expect(int(_payload_of(sow_shared).get("sequence", -1)) + 1 == sow_sequence,
		"Each sow advances the authoritative sequence by one")
	_expect(await _wait_member_sequence("b", sow_sequence, 15000),
		"B has caught up with A's sow commits before it acts")

	# (4) Without a grant, B's harvest of A's cell is refused by the authority's
	# farm rule, not by any client-side check.
	var sow_at: float = maxf(float(sow_shared.get("at_utc", 0.0)), float(sow_plain.get("at_utc", 0.0)))
	var h1: float = sow_at + GREENS_DURATION * 4.0 + 120.0
	var before_refusal: int = _disk_sequence()
	var refused := await _submit("b", "b-plain-04", {
		"id": "vb-b-h04-nogrant", "kind": "harvest", "field_id": SOW_FIELD_GRANTED,
		"cell_id": SOW_CELL, "at_utc": h1})
	var refused_payload := _payload_of(refused)
	_expect(bool(refused.get("sent", false)),
		"B's ungranted harvest was submitted to the authority")
	_expect(str(refused_payload.get("reason", "")) == "theft_disabled",
		"The authority refuses B's harvest of A's ungranted cell")
	_expect(not bool(refused_payload.get("authorized", true)),
		"The refusal carries the authority's authorized=false stamp")
	_expect(refused_payload.has("stage") and refused_payload.has("duplicate"),
		"The refusal carries the authority's execution envelope, not a client-side verdict")
	_expect(int(refused_payload.get("sequence", -1)) == before_refusal,
		"The refused harvest does not advance the world sequence")
	_expect(_disk_sequence() == before_refusal,
		"The persisted world is unchanged by the refused harvest")

	# (5) A grants exactly one named field; a second grant is issued and revoked
	# so the surviving state is one grant, not two.
	var grant_one := await _social("a", "grant-shared", "grant", {
		"player_id": B_ID, "kinds": ["harvest"], "fields": [SOW_FIELD_GRANTED],
		"expires_at": 0.0})
	_expect(bool(grant_one.get("ok", false)),
		"A grants B harvest rights on one named field")
	var a_view := _social_state(grant_one)
	var grant_shared: String = _grant_id_for_field(a_view, SOW_FIELD_GRANTED, "out")
	_expect(not grant_shared.is_empty(), "The field-scoped grant is visible to its issuer")
	_expect(_count_grants(a_view, "out") == 1, "A sees exactly one outgoing grant")

	var grant_two := await _social("a", "grant-plain", "grant", {
		"player_id": B_ID, "kinds": ["harvest"], "fields": [SOW_FIELD_PLAIN],
		"expires_at": 0.0})
	_expect(bool(grant_two.get("ok", false)), "A issues a second named-field grant")
	var a_view_two := _social_state(grant_two)
	var grant_plain: String = _grant_id_for_field(a_view_two, SOW_FIELD_PLAIN, "out")
	_expect(not grant_plain.is_empty() and grant_plain != grant_shared,
		"The second grant is a separate record")
	_expect(_count_grants(a_view_two, "out") == 2, "A sees both outgoing grants")

	var revoked := await _social("a", "revoke-plain", "revoke", {"id": grant_plain})
	_expect(bool(revoked.get("ok", false)), "A revokes the second grant")
	var a_view_three := _social_state(revoked)
	_expect(_count_grants(a_view_three, "out") == 1
		and _grant_id_for_field(a_view_three, SOW_FIELD_PLAIN, "out").is_empty(),
		"The revoked grant leaves A's view")

	var b_view_res := await _social("b", "state-b-grants", "state", {})
	var b_view := _social_state(b_view_res)
	_expect(_count_grants(b_view, "in") == 1,
		"B sees exactly one incoming grant after the revocation")
	_expect(not _grant_id_for_field(b_view, SOW_FIELD_GRANTED, "in").is_empty(),
		"The surviving grant still names the shared field")
	_expect(_grant_id_for_field(b_view, SOW_FIELD_PLAIN, "in").is_empty(),
		"The revoked field grant is gone from B's view")

	# (6) B is refused in the revoked/non-granted field and accepted in the
	# granted field; the authority stamps the grant on the accepted command.
	var plain_attempt := await _submit("b", "b-plain-05", {
		"id": "vb-b-h05-nogrant", "kind": "harvest", "field_id": SOW_FIELD_PLAIN,
		"cell_id": SOW_CELL, "at_utc": h1 + 10.0})
	_expect(str(_payload_of(plain_attempt).get("reason", "")) == "theft_disabled",
		"B is refused in the field whose grant was revoked")

	var granted := await _submit("b", "b-granted-04", {
		"id": "vb-b-h04-granted", "kind": "harvest", "field_id": SOW_FIELD_GRANTED,
		"cell_id": SOW_CELL, "at_utc": h1 + 20.0})
	var granted_payload := _payload_of(granted)
	_expect(bool(granted.get("ok", false)),
		"B harvests the field the owner granted")
	_expect(bool(granted_payload.get("authorized", false)),
		"The accepted harvest carries the authority's authorized=true stamp")
	_expect(int(granted_payload.get("reward_amount", 0)) == 1,
		"The granted harvest yields exactly one basket")
	_expect(int((granted_payload.get("bags", {}) as Dictionary).get(CROP, 0)) == 1,
		"The granted basket enters B's own bag")

	# Clear B's bag so the later gift can be measured as the bag's only content.
	var b_return := await _submit("b", "b-return", {
		"id": "vb-b-gift-back", "kind": "gift", "to_id": A_ID,
		"crop_id": CROP, "amount": 1, "at_utc": h1 + 30.0})
	_expect(bool(b_return.get("ok", false)),
		"B returns its basket to A so the measured gift is unambiguous")
	_expect(int((_payload_of(b_return).get("bags", {}) as Dictionary).get(CROP, -1)) == 0,
		"B's bag is empty after returning the basket")

	# (7) A harvests a named mature crop, gifts one basket to B, and replays the
	# same delivery id: the authoritative bag moves exactly once.
	var harvest_a := await _submit("a", "a-harvest", {
		"id": "vb-a-harvest-03", "kind": "harvest", "field_id": HARVEST_FIELD,
		"cell_id": HARVEST_CELL, "at_utc": h1 + 40.0})
	_expect(bool(harvest_a.get("ok", false)), "A harvests a named mature crop")
	_expect(int((_payload_of(harvest_a).get("bags", {}) as Dictionary).get(CROP, 0)) == 2,
		"A's bag holds the returned basket plus the new harvest")

	var gift := await _submit("a", "a-gift", {
		"id": "vb-a-gift-once", "kind": "gift", "to_id": B_ID,
		"crop_id": CROP, "amount": 1, "at_utc": h1 + 50.0})
	var gift_payload := _payload_of(gift)
	_expect(bool(gift.get("ok", false)) and not bool(gift_payload.get("duplicate", true)),
		"A gifts one named harvest to B")
	_expect(int(gift_payload.get("bags", {}).get(CROP, -1)) == 1,
		"A's bag drops by exactly one after the gift")
	var gift_sequence: int = int(gift_payload.get("sequence", -1))

	var replay := await _submit("a", "a-gift-replay", {
		"id": "vb-a-gift-once", "kind": "gift", "to_id": B_ID,
		"crop_id": CROP, "amount": 1, "at_utc": h1 + 50.0})
	var replay_payload := _payload_of(replay)
	_expect(bool(replay.get("ok", false)) and bool(replay_payload.get("duplicate", false)),
		"Replaying the same delivery id is reported as duplicate")
	_expect(int(replay_payload.get("sequence", -1)) == gift_sequence,
		"The replay does not advance the world sequence")
	_expect(int(replay_payload.get("bags", {}).get(CROP, -1)) == 1,
		"The replay does not move produce a second time")

	var b_summary := await _summary("b")
	_expect(bool(b_summary.get("ok", false)),
		"B restores a fresh authoritative summary after the gift")
	var b_after_gift := _member_state("b")
	_expect(_same_bag(_nonempty_bag(_bags_of(b_after_gift), "b"), {CROP: 1}),
		"B's restored bag holds exactly the gifted produce")

	# (8) Two members release a build for the same named yard slot at the same
	# moment. Exactly one commits; the world stores one construction record.
	var pre_build_sequence: int = _disk_sequence()
	_expect(await _wait_member_sequence("a", pre_build_sequence, 15000),
		"A is at the authority's sequence before building")
	_expect(await _wait_member_sequence("b", pre_build_sequence, 15000),
		"B is at the authority's sequence before building")
	var gate: String = dir.path_join("gate-build")
	var build_a := _send_step("a", {"op": "submit", "id": "build-a", "gate": gate,
		"command": {"id": "vb-build-a", "kind": "build", "slot_id": BUILD_SLOT,
			"blueprint": BUILD_BLUEPRINT, "at_utc": h1 + 60.0}})
	var build_b := _send_step("b", {"op": "submit", "id": "build-b", "gate": gate,
		"command": {"id": "vb-build-b", "kind": "build", "slot_id": BUILD_SLOT,
			"blueprint": BUILD_BLUEPRINT, "at_utc": h1 + 60.0}})
	_write(gate, "go")
	var race_a := await _wait_result("a", build_a)
	var race_b := await _wait_result("b", build_b)
	var a_won: bool = bool(race_a.get("ok", false))
	var b_won: bool = bool(race_b.get("ok", false))
	_expect(a_won != b_won, "Exactly one member wins the same yard slot")
	var winner: String = "a" if a_won else "b"
	var loser: String = "b" if a_won else "a"
	var winner_id: String = A_ID if a_won else B_ID
	var loser_result: Dictionary = race_b if a_won else race_a
	_expect(str(loser_result.get("reason", "")) in ["stale_precondition", "occupied"],
		"The losing attempt is refused by the authority, not applied")
	_expect(_disk_sequence() == pre_build_sequence + 1,
		"The race commits exactly one construction event")
	var built: Dictionary = _disk_buildings()
	_expect(built.size() == 1 and built.has(BUILD_SLOT),
		"The world stores exactly one construction record for the slot")
	var record: Dictionary = built.get(BUILD_SLOT, {}) as Dictionary
	_expect(str(record.get("owner", "")) == winner_id,
		"The construction record belongs to the winner")
	_expect(str(record.get("blueprint", "")) == BUILD_BLUEPRINT,
		"The construction record keeps the requested blueprint")
	_expect(int(record.get("done_utc", 0)) - int(record.get("started_utc", 0)) == BUILD_SECONDS,
		"The construction record keeps the cottage duration")

	var retry := await _submit(loser, "build-retry", {
		"id": "vb-build-retry", "kind": "build", "slot_id": BUILD_SLOT,
		"blueprint": BUILD_BLUEPRINT, "at_utc": h1 + 61.0})
	_expect(str(_payload_of(retry).get("reason", "")) == "occupied",
		"A fresh-basis retry on the occupied slot is refused as occupied")
	_expect(_disk_sequence() == pre_build_sequence + 1,
		"The occupied retry adds no event")
	_expect(_disk_buildings().size() == 1,
		"The occupied retry adds no second construction record")

	# Capture the pre-stop view from a fresh summary on both members.
	var a_sum := await _summary("a")
	var b_sum := await _summary("b")
	_expect(bool(a_sum.get("ok", false)) and bool(b_sum.get("ok", false)),
		"Both members restore a summary containing the new house")
	var a_pre := _member_state("a")
	var b_pre := _member_state("b")
	_expect(_building_owner(a_pre, BUILD_SLOT) == winner_id,
		"A's restored view names the winner as the house owner")
	_expect(_building_owner(b_pre, BUILD_SLOT) == winner_id,
		"B's restored view names the winner as the house owner")
	_expect(_same_bag(_nonempty_bag(_bags_of(b_pre), "b"), {CROP: 1}),
		"B's bag still holds exactly the gifted produce before the restart")

	var pre_sequence: int = _disk_sequence()
	var pre_grants_a: Array = _grant_signature(_grants_of(a_pre))
	var pre_grants_b: Array = _grant_signature(_grants_of(b_pre))
	var pre_roster: Array = _roster_signature(_roster_of(b_pre))
	var pre_building: Dictionary = _building_record(b_pre, BUILD_SLOT)
	var pre_state: String = _building_state(b_pre, BUILD_SLOT)
	_expect(str(pre_state) == "building", "The house is under construction before the restart")
	_expect(pre_grants_b.size() == 1 and pre_roster.size() == 2,
		"The pre-stop grant and roster state is one grant and two members")

	# (9) Clean stop, then restart from the same save directory and port.
	await _stop_authority()
	var stopped: Dictionary = _read_json(world_dir.path_join("server-status.json"))
	_expect(str(stopped.get("state", "")) == "stopped" and bool(stopped.get("saved", false)),
		"The authority reports a clean stop with a successful save")
	var disk_stop := _disk_farm()
	_expect(disk_stop != null, "The stopped authority wrote a restorable world")
	if disk_stop != null:
		_expect(disk_stop.event_sequence() == pre_sequence,
			"The stopped world kept the last committed sequence")
		var stopped_build := (disk_stop.snapshot().get("buildings", {}) as Dictionary)
		_expect(stopped_build.size() == 1 and str(
			(stopped_build.get(BUILD_SLOT, {}) as Dictionary).get("owner", "")) == winner_id,
			"The stopped world persisted the single house record")
		_expect(int(disk_stop.bag(B_ID).get(CROP, 0)) == 1,
			"The stopped world persisted B's gifted produce")

	_expect(await _wait_reconnecting("a", 20000),
		"A starts reconnecting after the authority disappears")
	_expect(await _wait_reconnecting("b", 20000),
		"B starts reconnecting after the authority disappears")
	_expect(_refused_reasons("a").is_empty() and _lost_reasons("a").is_empty(),
		"A treats the outage as transient, not a permanent loss")
	_expect(_refused_reasons("b").is_empty() and _lost_reasons("b").is_empty(),
		"B treats the outage as transient, not a permanent loss")

	var ready_before_a: int = int(_member_state("a").get("state_ready_count", 0))
	var ready_before_b: int = int(_member_state("b").get("state_ready_count", 0))
	await create_timer(0.3).timeout
	server_pid = _start_server()
	_expect(server_pid > 0, "The authority restarts on the same port")
	_expect(server_pid > 0 and await _wait_status("running", 25000),
		"The restarted authority serves the same world directory")

	_expect(await _wait_reconnected("a", 45000),
		"A auto-reconnects within the client backoff window")
	_expect(await _wait_reconnected("b", 45000),
		"B auto-reconnects within the client backoff window")
	_expect(await _wait_state_ready_after("a", ready_before_a, 25000),
		"A receives a fresh authoritative summary after the reconnect")
	_expect(await _wait_state_ready_after("b", ready_before_b, 25000),
		"B receives a fresh authoritative summary after the reconnect")
	var a_reconnect: int = _last_reconnected("a")
	var b_reconnect: int = _last_reconnected("b")
	_expect(a_reconnect == pre_sequence,
		"A's reconnect reports the persisted sequence (%d vs %d)" % [a_reconnect, pre_sequence])
	_expect(b_reconnect == pre_sequence,
		"B's reconnect reports the persisted sequence (%d vs %d)" % [b_reconnect, pre_sequence])
	_expect(await _wait_roster("a", 2, 20000) and await _wait_roster("b", 2, 20000),
		"Both members see the two-row roster again after the reconnect")

	var a_post_res := await _social("a", "state-a-post", "state", {})
	var b_post_res := await _social("b", "state-b-post", "state", {})
	_expect(bool(a_post_res.get("ok", false)) and bool(b_post_res.get("ok", false)),
		"Both members re-read their social state after the restart")
	var a_post := _member_state("a")
	var b_post := _member_state("b")

	var post_record: Dictionary = _building_record(b_post, BUILD_SLOT)
	_expect(str(post_record.get("owner", "")) == winner_id
		and str(post_record.get("blueprint", "")) == BUILD_BLUEPRINT,
		"The house survives the restart with the same owner and slot")
	_expect(int(post_record.get("started_utc", -1)) == int(pre_building.get("started_utc", -2))
		and int(post_record.get("done_utc", -1)) == int(pre_building.get("done_utc", -2)),
		"The house keeps its construction times across the restart")
	_expect(str(_building_state(b_post, BUILD_SLOT)) == pre_state,
		"The house keeps its construction state across the restart")
	_expect(_same_bag(_nonempty_bag(_bags_of(b_post), "b"), {CROP: 1}),
		"B's restored bag still holds exactly the gifted produce after the restart")
	_expect(int(_nonempty_bag(_bags_of(a_post), "a").get(CROP, 0)) == 1,
		"A's restored bag is unchanged by the restart")
	_expect(_grant_signature(_grants_of(a_post)) == pre_grants_a,
		"A's grant state is unchanged across the restart")
	_expect(_grant_signature(_grants_of(b_post)) == pre_grants_b,
		"B's grant and revocation state is unchanged across the restart")
	_expect(_roster_signature(_roster_of(a_post)) == pre_roster,
		"A's neighbour roster is the same after the reconnect")
	_expect(_roster_signature(_roster_of(b_post)) == pre_roster,
		"B's neighbour roster is the same after the reconnect")
	_expect(_roster_ids(b_post).size() == 2 and _roster_ids(b_post).has(A_ID)
		and _roster_ids(b_post).has(B_ID),
		"The restored roster still names both distinct players")
	_expect(_disk_sequence() == pre_sequence,
		"The restarted world did not grow a new event on its own")

	# (10) Low-interruption bound and ordinary-use reachability for member B.
	var b_metrics: Dictionary = b_post.get("summary_metrics", {}) as Dictionary
	var committed: int = _disk_committed()
	_expect(int(b_post.get("summary_count", 0)) <= MAX_SUMMARIES,
		"B receives a bounded number of summary deliveries")
	_expect(int(b_metrics.get("bytes", MAX_SUMMARY_BYTES + 1)) <= MAX_SUMMARY_BYTES,
		"B's summary document stays inside the bounded size")
	_expect(int(b_metrics.get("cells", 0)) >= 1 and int(b_metrics.get("cells", 0)) <= MAX_SUMMARY_CELLS,
		"B's summary carries a bounded aggregate cell map")
	_expect(not bool(b_metrics.get("has_history", true)),
		"B's summary carries counters, not an event or per-command history")
	_expect(int(b_post.get("changes_count", 0)) <= committed,
		"B receives at most one change per committed command")
	_expect(int(b_post.get("changes_without_command", 1)) == 0,
		"Every change B sees is a committed command, not a per-cell message")
	_expect(int(b_post.get("summary_count", 0)) >= 1,
		"B's bounded summary was actually delivered")
	_expect(_refused_reasons("b").is_empty() and _lost_reasons("b").is_empty(),
		"B was never refused or cut off during ordinary use")
	_expect(bool(b_post.get("joined", false))
		and int(b_post.get("state_ready_count", 0)) >= 2
		and (b_post.get("reconnected", []) as Array).size() >= 1,
		"B loaded, viewed and reconnected without a feature gate")
	_expect(_only_state_actions(b_post),
		"B's only social action was reading its own state")
	_expect(not ("set_theft" in (b_post.get("submitted_kinds", []) as Array)),
		"B never enabled theft")
	_expect(not bool(b_post.get("theft_any", true)) and not bool(a_post.get("theft_any", true)),
		"No member enabled theft in the authoritative world")

	await _shutdown()
	_finish()


# ------------------------------------------------------------ parent helpers

func _social(who_id: String, request_id: String, action: String, args: Dictionary = {}) -> Dictionary:
	return await _run_step(who_id, {"op": "social", "request_id": request_id,
		"action": action, "args": args})


func _summary(who_id: String) -> Dictionary:
	return await _run_step(who_id, {"op": "summary"})


func _submit(who_id: String, step_id: String, command: Dictionary) -> Dictionary:
	return await _run_step(who_id, {"op": "submit", "id": step_id, "command": command})


func _submit_now(who_id: String, step_id: String, command: Dictionary) -> Dictionary:
	return await _run_step(who_id, {"op": "submit", "id": step_id, "at": "now",
		"command": command})


func _run_step(who_id: String, step: Dictionary) -> Dictionary:
	var index: int = _send_step(who_id, step)
	return await _wait_result(who_id, index)


func _send_step(who_id: String, step: Dictionary) -> int:
	var index: int = int(next_step.get(who_id, 0))
	next_step[who_id] = index + 1
	var copy: Dictionary = step.duplicate(true)
	copy["index"] = index
	_write_json_atomic(_step_path(who_id, index), copy)
	return index


func _wait_result(who_id: String, index: int, timeout_ms: int = 30000) -> Dictionary:
	var path: String = _result_path(who_id, index)
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var parsed: Dictionary = _read_json(path)
		if bool(parsed.get("done", false)):
			return parsed
		await create_timer(0.03).timeout
	return _read_json(path)


func _member_state(who_id: String) -> Dictionary:
	# The member replaces this file with remove+rename, so a read can land in
	# the gap and see no file at all. Once the file has been observed, retry
	# briefly instead of reporting an empty state (which would look like a
	# missing house, bag or reconnect event).
	var path: String = _state_path(who_id)
	for attempt: int in range(40):
		var state: Dictionary = _read_json(path)
		if not state.is_empty():
			_state_seen[path] = true
			return state
		if not _state_seen.has(path):
			return {}
		OS.delay_msec(5)
	return {}


func _wait_joined(who_id: String, timeout_ms: int) -> bool:
	return await _wait_until(func() -> bool:
		return bool(_member_state(who_id).get("joined", false)), timeout_ms)


func _wait_state_ready(who_id: String, minimum: int, timeout_ms: int) -> bool:
	return await _wait_until(func() -> bool:
		return int(_member_state(who_id).get("state_ready_count", 0)) >= minimum, timeout_ms)


func _wait_state_ready_after(who_id: String, previous: int, timeout_ms: int) -> bool:
	return await _wait_until(func() -> bool:
		return int(_member_state(who_id).get("state_ready_count", 0)) > previous, timeout_ms)


func _wait_roster(who_id: String, minimum: int, timeout_ms: int) -> bool:
	return await _wait_until(func() -> bool:
		return _roster_of(_member_state(who_id)).size() >= minimum, timeout_ms)


func _wait_member_sequence(who_id: String, target: int, timeout_ms: int) -> bool:
	return await _wait_until(func() -> bool:
		return int(_member_state(who_id).get("last_sequence", -1)) >= target, timeout_ms)


func _wait_reconnecting(who_id: String, timeout_ms: int) -> bool:
	return await _wait_until(func() -> bool:
		return not (_member_state(who_id).get("reconnect_events", []) as Array).is_empty(),
		timeout_ms)


func _wait_reconnected(who_id: String, timeout_ms: int) -> bool:
	return await _wait_until(func() -> bool:
		return not (_member_state(who_id).get("reconnected", []) as Array).is_empty(),
		timeout_ms)


func _last_reconnected(who_id: String) -> int:
	var rows: Array = _member_state(who_id).get("reconnected", []) as Array
	return int(rows[-1]) if not rows.is_empty() else -1


func _refused_reasons(who_id: String) -> Array:
	return _member_state(who_id).get("refused", []) as Array


func _lost_reasons(who_id: String) -> Array:
	return _member_state(who_id).get("lost", []) as Array


func _wait_until(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await create_timer(0.03).timeout
	return bool(condition.call())


func _payload_of(result: Dictionary) -> Dictionary:
	var payload: Variant = result.get("payload", {})
	return payload if payload is Dictionary else {}


func _social_state(result: Dictionary) -> Dictionary:
	var payload: Dictionary = _payload_of(result)
	var state: Variant = payload.get("state", {})
	return state if state is Dictionary else {}


func _count_grants(state: Dictionary, direction: String) -> int:
	var count: int = 0
	for row: Variant in state.get("grants", []) as Array:
		if row is Dictionary and str((row as Dictionary).get("direction", "")) == direction:
			count += 1
	return count


func _grant_id_for_field(state: Dictionary, field_id: String, direction: String) -> String:
	for row: Variant in state.get("grants", []) as Array:
		if not row is Dictionary:
			continue
		var grant: Dictionary = row
		if str(grant.get("direction", "")) != direction:
			continue
		if (grant.get("fields", []) as Array).has(field_id):
			return str(grant.get("id", ""))
	return ""


func _grants_of(member_state: Dictionary) -> Array:
	return member_state.get("grants", []) as Array


func _grant_signature(rows: Array) -> Array:
	var out: Array = []
	for row: Variant in rows:
		if not row is Dictionary:
			continue
		var grant: Dictionary = row
		out.append("%s|%s|%s|%s|%s" % [
			str(grant.get("id", "")), str(grant.get("from", "")), str(grant.get("to", "")),
			JSON.stringify(grant.get("kinds", [])), JSON.stringify(grant.get("fields", []))])
	out.sort()
	return out


func _roster_of(member_state: Dictionary) -> Array:
	return member_state.get("roster", []) as Array


func _roster_signature(rows: Array) -> Array:
	var out: Array = []
	for row: Variant in rows:
		if not row is Dictionary:
			continue
		var entry: Dictionary = row
		out.append("%s|%s|%s" % [str(entry.get("player_id", "")),
			str(entry.get("role", "")), str(entry.get("name", ""))])
	out.sort()
	return out


func _roster_ids(member_state: Dictionary) -> Array:
	var ids: Array = []
	for row: Variant in _roster_of(member_state):
		if row is Dictionary and not str((row as Dictionary).get("player_id", "")).is_empty():
			ids.append(str((row as Dictionary).player_id))
	return ids


func _bags_of(member_state: Dictionary) -> Dictionary:
	var bags: Variant = member_state.get("bags", {})
	return bags if bags is Dictionary else {}


func _nonempty_bag(bags: Dictionary, who_id: String) -> Dictionary:
	var result: Dictionary = {}
	var bag: Variant = bags.get(who_id, {})
	if not bag is Dictionary:
		return result
	for crop_id: Variant in (bag as Dictionary):
		var amount: int = int((bag as Dictionary)[crop_id])
		if amount != 0:
			result[str(crop_id)] = amount
	return result


func _same_bag(actual: Dictionary, expected: Dictionary) -> bool:
	if actual.size() != expected.size():
		return false
	for crop_id: String in expected:
		if int(actual.get(crop_id, -1)) != int(expected[crop_id]):
			return false
	return true


func _building_record(member_state: Dictionary, slot_id: String) -> Dictionary:
	var buildings: Variant = member_state.get("buildings", {})
	if not buildings is Dictionary:
		return {}
	var record: Variant = (buildings as Dictionary).get(slot_id, {})
	return record if record is Dictionary else {}


func _building_owner(member_state: Dictionary, slot_id: String) -> String:
	return str(_building_record(member_state, slot_id).get("owner", ""))


func _building_state(member_state: Dictionary, slot_id: String) -> String:
	var at: Variant = member_state.get("buildings_at", {})
	if not at is Dictionary:
		return ""
	var row: Variant = (at as Dictionary).get(slot_id, {})
	if not row is Dictionary:
		return ""
	return str((row as Dictionary).get("state", ""))


func _only_state_actions(member_state: Dictionary) -> bool:
	for action: Variant in member_state.get("social_actions", []) as Array:
		if str(action) != "state":
			return false
	return true


func _disk_farm() -> FarmState:
	if world_dir.is_empty():
		return null
	var store := FarmStore.new(world_dir)
	var loaded: Dictionary = store.load_state()
	if not bool(loaded.get("ok", false)) or not loaded.has("farm"):
		return null
	var farm := FarmState.new()
	if not farm.restore_snapshot(loaded.get("farm")):
		return null
	return farm


func _disk_sequence() -> int:
	var farm := _disk_farm()
	return farm.event_sequence() if farm != null else -1


func _disk_committed() -> int:
	var farm := _disk_farm()
	return farm.committed_command_count() if farm != null else 0


func _disk_buildings() -> Dictionary:
	var farm := _disk_farm()
	if farm == null:
		return {}
	var buildings: Variant = farm.snapshot().get("buildings", {})
	return buildings if buildings is Dictionary else {}


func _start_server() -> int:
	var args := PackedStringArray([
		"--headless", "--path", repo_root.path_join("Game"),
		"--script", repo_root.path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % START, "--run-seconds=0",
	])
	return OS.create_process(OS.get_executable_path(), args, false)


func _start_member(who_id: String) -> int:
	var args := PackedStringArray([
		"--headless", "--path", repo_root.path_join("Game"),
		"--script", repo_root.path_join("tests/village_beta_test.gd"), "--",
		"--role=member", "--who=" + who_id, "--dir=" + dir,
		"--cert-file=" + world_dir.path_join("server.crt"),
		"--invite-file=" + world_dir.path_join("invite.bin"),
		"--url=wss://127.0.0.1:%d" % port, "--world=" + WORLD,
		"--player-id=" + _id_of(who_id), "--name=" + _name_of(who_id),
	])
	return OS.create_process(OS.get_executable_path(), args, false)


func _wait_status(expected: String, timeout_ms: int) -> bool:
	var path: String = world_dir.path_join("server-status.json")
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if str(_read_json(path).get("state", "")) == expected:
			return true
		await create_timer(0.05).timeout
	return str(_read_json(path).get("state", "")) == expected


func _stop_authority() -> void:
	if server_pid > 0:
		_write(world_dir.path_join("stop"), "stop")
		await _wait_process(server_pid, 20000)
	_expect(server_pid <= 0 or not OS.is_process_running(server_pid),
		"Stopping the room ends the authority process")
	server_pid = -1


func _shutdown() -> void:
	for who_id: String in member_pids:
		_write(dir.path_join("stop-" + who_id), "stop")
	for who_id: String in member_pids:
		var pid: int = int(member_pids.get(who_id, 0))
		if pid > 0:
			await _wait_process(pid, 8000)
			if OS.is_process_running(pid):
				OS.kill(pid)
				await _wait_process(pid, 5000)
	if server_pid > 0:
		_write(world_dir.path_join("stop"), "stop")
		await _wait_process(server_pid, 15000)
		if OS.is_process_running(server_pid):
			OS.kill(server_pid)
			await _wait_process(server_pid, 5000)
	server_pid = -1


# ================================================================== member

func _run_member() -> void:
	_write_state()
	_setup_client()
	if not fatal_reason.is_empty():
		_write_state()
		quit(1)
		return
	var deadline: int = Time.get_ticks_msec() + int(MEMBER_LIFETIME * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(dir.path_join("stop-" + who)):
			break
		if not busy and FileAccess.file_exists(_step_path(who, step_index)):
			busy = true
			var step: Dictionary = _read_json(_step_path(who, step_index))
			var result: Dictionary = await _perform_step(step, step_index)
			_write_json_atomic(_result_path(who, step_index), result)
			step_index += 1
			busy = false
		_write_state()
		await create_timer(0.05).timeout
	_write_state()
	if client != null:
		client.close()
	quit(0)


func _setup_client() -> void:
	var certificate_pem: String = FileAccess.get_file_as_string(cert_file)
	var invite_bytes: PackedByteArray = FileAccess.get_file_as_bytes(invite_file)
	if certificate_pem.is_empty():
		fatal_reason = "certificate_missing"
		return
	if invite_bytes.size() != 32:
		fatal_reason = "invite_missing"
		return
	var grant: Dictionary = WorldInvite.make(GRANT_ID, invite_bytes, WorldInvite.MEMBER,
		world, 0.0, false)
	if grant.is_empty():
		fatal_reason = "invalid_grant"
		return
	var code: String = WorldJoinCode.encode(grant, url, certificate_pem, "localhost")
	if code.is_empty():
		fatal_reason = "invalid_join_code"
		return
	client = WorldClient.new()
	client.name = "VillageClient"
	root.add_child(client)
	client.state_ready.connect(_on_state_ready)
	client.refused.connect(func(reason: String) -> void: refused_reasons.append(reason))
	client.lost.connect(func(reason: String) -> void: lost_reasons.append(reason))
	client.reconnecting.connect(_on_reconnecting)
	client.reconnected.connect(func(sequence: int) -> void: reconnected_sequences.append(sequence))
	client.committed.connect(_on_committed)
	client.changed.connect(_on_changed)
	if not client.start(code, player_id, display_name):
		fatal_reason = "start_refused"
		return
	client.member.reply_received.connect(_on_reply)
	client.member.social_result.connect(_on_social)
	client.member.roster_changed.connect(func(rows: Array[Dictionary]) -> void:
		roster_rows = []
		roster_rows.assign(rows))


func _on_state_ready(farm: RefCounted, _decorations: RefCounted, now_utc: float) -> void:
	last_farm = farm
	last_now = now_utc
	state_ready_count += 1
	_write_state()


func _on_reconnecting(attempt: int, delay: float) -> void:
	reconnect_events.append({"attempt": attempt, "delay": delay})
	_write_state()


func _on_committed(request_id: String, reply: Dictionary) -> void:
	replies[request_id] = reply
	_write_state()


func _on_changed(entry: Dictionary) -> void:
	changes_count += 1
	var command: Variant = entry.get("command", null)
	if not command is Dictionary:
		changes_without_command += 1
	_write_state()


func _on_reply(request_id: String, payload: Dictionary) -> void:
	if request_id == "summary":
		summary_count += 1
		summary_metrics = _summary_metrics(payload)
	elif request_id == "catch_up":
		catch_up_count += 1
	_write_state()


func _on_social(request_id: String, payload: Dictionary) -> void:
	social_results[request_id] = payload
	_write_state()


func _summary_metrics(payload: Dictionary) -> Dictionary:
	var cells: int = 0
	var fields: Variant = payload.get("fields", {})
	if fields is Dictionary:
		for field_id: Variant in (fields as Dictionary):
			var field: Variant = (fields as Dictionary)[field_id]
			if field is Dictionary:
				cells += (field as Dictionary).size()
	return {
		"bytes": JSON.stringify(payload).to_utf8_buffer().size(),
		"cells": cells,
		"committed_sequence": int(payload.get("committed_sequence", -1)),
		"has_history": payload.has("events") or payload.has("history") or payload.has("tail"),
	}


func _perform_step(step: Dictionary, index: int) -> Dictionary:
	var op: String = str(step.get("op", ""))
	var result: Dictionary = {
		"done": true, "index": index, "op": op, "id": str(step.get("id", "")),
		"sent": false, "ok": false, "reason": "", "payload": {}, "timeout": false,
		"at_utc": 0.0, "last_sequence": _sequence(),
	}
	match op:
		"submit":
			await _do_submit(step, result)
		"social":
			await _do_social(step, result)
		"summary":
			await _do_summary(result)
		"noop":
			result.ok = true
		_:
			result.reason = "unknown_step"
	result.last_sequence = _sequence()
	return result


func _do_submit(step: Dictionary, result: Dictionary) -> void:
	if client == null or client.member == null:
		result.reason = "no_client"
		return
	var command: Dictionary = (step.get("command", {}) as Dictionary).duplicate(true)
	if str(step.get("at", "")) == "now" or not command.has("at_utc"):
		command["at_utc"] = client.world_time()
	result.at_utc = float(command.get("at_utc", 0.0))
	submitted_kinds.append(str(command.get("kind", "")))
	var gate: String = str(step.get("gate", ""))
	if not gate.is_empty() and not await _wait_file(gate, STEP_TIMEOUT_MS):
		result.reason = "gate_timeout"
		return
	var id: String = str(command.get("id", ""))
	replies.erase(id)
	result.sent = client.submit(command)
	if not result.sent:
		result.reason = "not_sent"
		return
	if await _wait_key(replies, id, STEP_TIMEOUT_MS):
		result.payload = replies[id]
		result.ok = bool(result.payload.get("ok", false))
		result.reason = str(result.payload.get("reason", ""))
	else:
		result.timeout = true
		result.reason = "timeout"


func _do_social(step: Dictionary, result: Dictionary) -> void:
	if client == null or client.member == null:
		result.reason = "no_client"
		return
	var request_id: String = str(step.get("request_id", ""))
	var action: String = str(step.get("action", ""))
	var args: Dictionary = (step.get("args", {}) as Dictionary)
	social_actions.append(action)
	social_results.erase(request_id)
	result.sent = client.member.request_social(request_id, action, args)
	if not result.sent:
		result.reason = "not_sent"
		return
	if await _wait_key(social_results, request_id, STEP_TIMEOUT_MS):
		result.payload = social_results[request_id]
		result.ok = bool(result.payload.get("ok", false))
		result.reason = str(result.payload.get("reason", ""))
	else:
		result.timeout = true
		result.reason = "timeout"


func _do_summary(result: Dictionary) -> void:
	if client == null or client.member == null:
		result.reason = "no_client"
		return
	var before: int = summary_count
	client.member.request_summary.rpc_id(1)
	result.ok = await _wait_counter(func() -> bool: return summary_count > before, STEP_TIMEOUT_MS)
	result.timeout = not result.ok
	if not result.ok:
		result.reason = "timeout"


func _sequence() -> int:
	return client.member.last_sequence if client != null and client.member != null else 0


func _write_state() -> void:
	if dir.is_empty() or who.is_empty():
		return
	var joined: bool = client != null and client.member != null and client.member.is_joined()
	var social: Dictionary = {}
	if client != null and client.member != null and client.member.social is Dictionary:
		social = client.member.social
	var state: Dictionary = {
		"who": who, "player_id": player_id, "display_name": display_name,
		"world_id": client.member.world_id if client != null and client.member != null else "",
		"role": client.member.role if client != null and client.member != null else "",
		"joined": joined, "fatal": fatal_reason,
		"refused": refused_reasons, "lost": lost_reasons,
		"reconnect_events": reconnect_events, "reconnected": reconnected_sequences,
		"state_ready_count": state_ready_count, "summary_count": summary_count,
		"catch_up_count": catch_up_count, "last_sequence": _sequence(),
		"summary_metrics": summary_metrics,
		"changes_count": changes_count, "changes_without_command": changes_without_command,
		"roster": roster_rows, "social_ready": not social.is_empty(),
		"grants": social.get("grants", []), "social_actions": social_actions,
		"submitted_kinds": submitted_kinds, "step_index": step_index,
		"bags": {}, "buildings": {}, "buildings_at": {}, "theft": {},
		"theft_any": false, "layout_fields": 0, "layout_cells": 0,
	}
	if last_farm != null:
		var snapshot: Dictionary = last_farm.snapshot()
		var theft: Variant = snapshot.get("theft", {})
		var theft_map: Dictionary = theft if theft is Dictionary else {}
		state.bags = {"a": last_farm.bag(A_ID), "b": last_farm.bag(B_ID)}
		state.buildings = snapshot.get("buildings", {})
		state.buildings_at = last_farm.buildings_at(last_now)
		state.theft = theft_map
		state.theft_any = not theft_map.is_empty()
		var layout: Variant = snapshot.get("layout", {})
		if layout is Dictionary:
			var fields: Variant = (layout as Dictionary).get("fields", [])
			if fields is Array:
				state.layout_fields = (fields as Array).size()
				var cells: int = 0
				for field: Variant in (fields as Array):
					if field is Dictionary and (field as Dictionary).get("cells", []) is Array:
						cells += ((field as Dictionary).get("cells", []) as Array).size()
				state.layout_cells = cells
	_write_json_atomic(_state_path(who), state)


# ------------------------------------------------------------ member helpers

func _wait_key(values: Dictionary, key: String, timeout_ms: int) -> bool:
	return await _wait_counter(func() -> bool: return values.has(key), timeout_ms)


func _wait_file(path: String, timeout_ms: int) -> bool:
	return await _wait_counter(func() -> bool: return FileAccess.file_exists(path), timeout_ms)


func _wait_counter(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await create_timer(0.02).timeout
	return bool(condition.call())


# ================================================================== shared

func _id_of(who_id: String) -> String:
	return A_ID if who_id == "a" else B_ID


func _name_of(who_id: String) -> String:
	return A_NAME if who_id == "a" else B_NAME


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _state_path(who_id: String) -> String:
	return dir.path_join("state-%s.json" % who_id)


func _step_path(who_id: String, index: int) -> String:
	return dir.path_join("step-%s-%d.json" % [who_id, index])


func _result_path(who_id: String, index: int) -> String:
	return dir.path_join("result-%s-%d.json" % [who_id, index])


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
	print("VILLAGE_BETA_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
	# Keep an isolated artifact directory only when a check failed, so the
	# reproduction is inspectable; a clean run leaves nothing behind.
	if failures.is_empty():
		_remove_tree(dir)
	quit(0 if failures.is_empty() else 1)


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


func _write_json_atomic(path: String, data: Dictionary) -> void:
	var temp: String = path + ".tmp"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(data))
	file.flush()
	file.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(temp, path)


func _remove_tree(path: String) -> void:
	if path.is_empty() or not DirAccess.dir_exists_absolute(path):
		return
	for name: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(name))
	for name: String in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(name))
	DirAccess.remove_absolute(path)
