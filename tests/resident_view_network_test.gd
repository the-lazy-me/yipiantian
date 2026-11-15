extends SceneTree
## M10-04 居民只读视图的真实网络测试：真实 `world_server.gd` + loopback WSS，
## RPC 25/26，而不是纯规则或 `HeadlessWorld` 接缝。
##
## 覆盖：
##   - 未启用：`--residents` 关闭时返回 disabled 且不下发居民行；
##   - 启用后：名册顺序、角色、人格、关系、记忆计数、购买投影与隐私边界；
##   - 重连：同一玩家重新加入后仍能读到同一份视图；
##   - 访客与匿名连接可以读，匿名视图不带玩家身份；
##   - 超预算请求得到 payload_too_large，连发触发 rate_limited，连接继续可用；
##   - 重启后视图与 `residents.json` 保持不变。
##
## 运行产物写在 `.local/verification/resident-view-network-<ticks>/`。一次只开
## 一个 `WorldClient`，因为它总是创建 `/root/WorldSession`。

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")
const NpcRoster = preload("res://npc/npc_roster.gd")
const NpcPersonality = preload("res://npc/npc_personality.gd")
const NpcRoles = preload("res://npc/npc_roles.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const PLAYER_SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMjI="
const START: float = 1800056400.0
## 重启必须晚于已保存的记忆时刻，否则加载器会把未来记忆当成损坏；仍要早于
## 300 秒的采购冷却与 120 秒的买单到期窗口，保证视图不再变化。
const RESTART_AT: float = START + 60.0
const WORLD: String = "world-resident-view-network"
const PLAYER_A: String = "player_00000000000000000000000000000201"
const PLAYER_B: String = "player_00000000000000000000000000000202"
const VISITOR_ID: String = "player_00000000000000000000000000000203"
const NAME_B: String = "阿木"
const VISITOR_NAME: String = "围观者"
const OVER_BUDGET_BYTES: int = 50000
const RATE_REQUESTS: int = 26
const ROW_KEYS: Array[String] = [
	"id", "display_name", "role", "traits", "relations", "memory_count",
	"last_memory_utc", "intents_consumed", "last_purchase",
	"pending_invitations", "last_invitation",
]
const RELATION_KEYS: Array[String] = [
	"id", "display_name", "affinity", "last_utc", "acts", "gifts",
]
const INVITATION_KEYS: Array[String] = [
	"from", "to", "status", "created_utc",
]
const FORBIDDEN_KEYS: Array[String] = [
	"cash", "accounts", "account", "owner", "bag", "goods", "summary",
	"entries", "intents", "gifts_utc", "state_version", "dialogue",
	"command_id",
]

var dir: String = ""
var world_dir: String = ""
var server_pid: int = 0
var port: int = 0
var url: String = ""
var checks: int = 0
var failures: Array[String] = []
var client: WorldClient
var _ready: bool = false
var _refusals: Array[String] = []
var _residents_pending: Dictionary = {}
var _command_pending: Dictionary = {}
var rows_before_stop: Array = []
var rows_member: Array = []
var view_before_stop: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/resident-view-network-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	if not await _start_authority(PLAYER_A, START, true):
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

	await _test_member(codes)
	await _close_client()
	await _test_visitor(codes)
	await _close_client()
	await _test_anonymous(codes)
	await _close_client()
	await _test_limits(codes)
	await _close_client()
	await _capture_before_stop(codes)
	await _close_client()

	var bytes_before_stop: PackedByteArray = _bytes(_residents_path())
	_expect(not bytes_before_stop.is_empty(),
		"The resident sidecar exists before the restart")
	await _stop_server()
	if not await _start_authority(PLAYER_A, RESTART_AT, true):
		_finish()
		return
	await _test_restart(_join_codes(), bytes_before_stop)
	await _close_client()
	await _stop_server()
	if not await _start_authority(PLAYER_A, RESTART_AT, false):
		_finish()
		return
	await _test_disabled(_join_codes(), bytes_before_stop)
	await _close_client()
	await _stop_server()
	_finish()


# ------------------------------------------------------------------ enabled

func _test_member(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The member joins over WSS")
	if client == null or not client.joined:
		return
	var opened: Dictionary = await _submit(FarmCommand.make_market_open(
		"resident-view-net-market", client.world_time()))
	_expect(bool(opened.get("ok", false)),
		"The member opens the merchant market (reason=%s)"
			% str(opened.get("reason", "")))

	var view: Dictionary = {}
	var rows: Array = []
	for attempt: int in 8:
		if attempt > 0:
			await create_timer(0.5).timeout
		view = _view(await _residents("resident-view-net-%d" % attempt))
		rows = view.get("residents", [])
		if _purchased(rows):
			break
	_expect(bool(view.get("available", false)),
		"The enabled authority answers a resident view")
	_expect(str(view.get("viewer", "")) == PLAYER_B,
		"The view carries the connection player as viewer")
	_expect(_purchased(rows),
		"The economy tick produced a real purchase for every resident")
	rows_member = rows.duplicate(true)
	_check_rows(rows, "member")


func _check_rows(rows: Array, label: String) -> void:
	_expect(rows.size() == NpcRoster.IDS.size(),
		"%s: the view has one row per roster resident" % label)
	var ids: Array = []
	for row_value: Variant in rows:
		if row_value is Dictionary:
			ids.append(str((row_value as Dictionary).get("id", "")))
	_expect(JSON.stringify(ids) == JSON.stringify(NpcRoster.IDS),
		"%s: rows follow NpcRoster.IDS order" % label)
	var serialized: String = JSON.stringify(rows)
	_expect(_forbidden_path(rows).is_empty(),
		"%s: no cash, account, goods, ownership or memory-body key is exposed" % label)
	_expect(not serialized.contains("\"entries\""),
		"%s: the memory entry table is not serialized" % label)
	_expect(not serialized.contains("\"summary\""),
		"%s: memory summaries are not serialized" % label)
	_expect(not serialized.contains("我向") and not serialized.contains("邀约"),
		"%s: no memory narrative text appears in the view" % label)

	var seed_value: int = _seed()
	for npc_id: String in NpcRoster.IDS:
		var row: Dictionary = _row(rows, npc_id)
		_expect(not row.is_empty(), "%s: %s has a row" % [label, npc_id])
		if row.is_empty():
			continue
		_expect(row.size() == ROW_KEYS.size(),
			"%s: %s has exactly the documented fields" % [label, npc_id])
		for key: String in ROW_KEYS:
			_expect(row.has(key), "%s: %s carries %s" % [label, npc_id, key])
		_expect(str(row.get("display_name", ""))
				== str(NpcRoster.DISPLAY_NAMES.get(npc_id, "")),
			"%s: %s keeps its roster name" % [label, npc_id])
		_expect(str(row.get("role", "")) == NpcRoles.role_of(npc_id),
			"%s: %s keeps its roster role" % [label, npc_id])
		var expected_traits: Dictionary = NpcPersonality.traits(
			npc_id, seed_value).traits
		var traits: Dictionary = row.get("traits", {})
		var traits_ok: bool = traits.size() == NpcPersonality.TRAITS.size()
		for trait_name: String in NpcPersonality.TRAITS:
			if not traits.has(trait_name) or not expected_traits.has(trait_name):
				traits_ok = false
				continue
			var value: int = int(traits[trait_name])
			if value != int(expected_traits[trait_name]):
				traits_ok = false
			if value < NpcPersonality.MIN_VALUE or value > NpcPersonality.MAX_VALUE:
				traits_ok = false
		_expect(traits_ok,
			"%s: %s traits match the seed-derived profile" % [label, npc_id])
		var relations: Array = row.get("relations", [])
		_expect(relations.size() == 2,
			"%s: %s relates to exactly two peers" % [label, npc_id])
		var total_acts: int = 0
		for peer_value: Variant in relations:
			var peer: Dictionary = peer_value
			_expect(peer.size() == RELATION_KEYS.size(),
				"%s: %s relation rows have the documented fields" % [label, npc_id])
			_expect(str(peer.get("id", "")) != npc_id,
				"%s: %s never relates to itself" % [label, npc_id])
			total_acts += int(peer.get("acts", 0))
		_expect(total_acts > 0,
			"%s: %s has at least one settled social action" % [label, npc_id])
		_expect(int(row.get("memory_count", 0)) == total_acts,
			"%s: %s memory rows match its own actions" % [label, npc_id])
		_expect(float(row.get("last_memory_utc", -1.0)) > 0.0,
			"%s: %s reports its latest memory time" % [label, npc_id])
		_expect(int(row.get("intents_consumed", 0)) > 0,
			"%s: %s reports consumed purchase intents" % [label, npc_id])
		var purchase: Dictionary = row.get("last_purchase", {})
		_expect(not purchase.is_empty(),
			"%s: %s projects its completed purchase" % [label, npc_id])
		_expect(EconomyCatalog.goods_ids().has(str(purchase.get("good", ""))),
			"%s: %s purchase names a catalog good" % [label, npc_id])
		_expect(float(purchase.get("at_utc", -1.0)) > 0.0,
			"%s: %s purchase carries its time" % [label, npc_id])
		_expect(int(row.get("pending_invitations", -1)) >= 0,
			"%s: %s reports a non-negative pending invitation count"
				% [label, npc_id])
		var invitation: Variant = row.get("last_invitation", null)
		_expect(invitation is Dictionary,
			"%s: %s reports a last invitation object" % [label, npc_id])
		if invitation is Dictionary and not (invitation as Dictionary).is_empty():
			_expect((invitation as Dictionary).size() == INVITATION_KEYS.size(),
				"%s: %s last invitation has the documented fields"
					% [label, npc_id])
			for key: String in INVITATION_KEYS:
				_expect((invitation as Dictionary).has(key),
					"%s: %s last invitation carries %s" % [label, npc_id, key])


# ------------------------------------------------------------------ readers

func _test_visitor(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("visitor", "")), VISITOR_ID,
		VISITOR_NAME, PLAYER_SECRET_A), "A named visitor joins with the visitor code")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.VISITOR,
		"The visitor code confers the visitor role")
	var reply: Dictionary = await _residents("visitor-resident-view")
	var view: Dictionary = _view(reply)
	_expect(bool(reply.get("ok", false)), "A visitor may read the resident view")
	_expect(bool(view.get("available", false)),
		"The visitor sees the enabled resident view")
	_expect(str(view.get("viewer", "")) == VISITOR_ID,
		"The visitor view names the visitor")
	var rows: Array = view.get("residents", [])
	_expect(JSON.stringify(rows) == JSON.stringify(rows_member),
		"The visitor sees the same resident rows as the member")
	_check_rows(rows, "visitor")
	var again: Dictionary = _view(await _residents("visitor-resident-view-2"))
	_expect(JSON.stringify(again.get("residents", [])) == JSON.stringify(rows),
		"A visitor can read the view repeatedly")
	_expect(_refusals.is_empty(), "The visitor read causes no authority loss")


func _test_anonymous(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), "", "", ""),
		"An anonymous connection joins")
	if client == null or not client.joined:
		return
	var reply: Dictionary = await _residents("anonymous-resident-view")
	var view: Dictionary = _view(reply)
	_expect(bool(reply.get("ok", false)),
		"An anonymous member may read the resident view")
	_expect(bool(view.get("available", false)),
		"The anonymous member sees the enabled resident view")
	_expect(str(view.get("viewer", "missing")) == "",
		"The anonymous view carries no player identity")
	_expect((view.get("residents", []) as Array).size() == NpcRoster.IDS.size(),
		"The anonymous view has the same resident count")
	_expect(_refusals.is_empty(), "The anonymous read causes no authority loss")


func _test_limits(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The member rejoins for budget and rate limits")
	if client == null or not client.joined:
		return
	var huge: String = JSON.stringify({
		"request_id": "resident-view-huge", "action": "state",
		"args": {"padding": "x".repeat(OVER_BUDGET_BYTES)},
	})
	_expect(huge.to_utf8_buffer().size() > 48 * 1024,
		"The oversized resident request really exceeds the wire budget")
	_residents_pending.erase("")
	client.member.residents_request.rpc_id(1, huge)
	var over_budget: Dictionary = await _residents_key("", 15000)
	_expect(str(over_budget.get("reason", "")) == "payload_too_large",
		"An over-budget resident request gets a named refusal")
	_expect(not str(over_budget.get("reason_text", "")).is_empty(),
		"The over-budget refusal carries a human-readable reason")
	var alive: Dictionary = _view(await _residents("resident-view-after-huge"))
	_expect(bool(alive.get("available", false)),
		"The connection keeps working after the over-budget refusal")

	for index: int in RATE_REQUESTS:
		var request_id: String = "resident-view-rate-%d" % index
		_residents_pending.erase(request_id)
		client.member.residents_request.rpc_id(1, JSON.stringify({
			"request_id": request_id, "action": "state", "args": {},
		}))
	var limited: bool = await _wait(func() -> bool:
		return _has_reason("rate_limited"), 15000)
	_expect(limited, "A rapid burst triggers a rate_limited refusal")
	await create_timer(1.5).timeout
	var recovered: Dictionary = _view(await _residents("resident-view-after-rate"))
	_expect(bool(recovered.get("available", false)),
		"The connection keeps working after the rate limit")
	_expect(_refusals.is_empty(),
		"Budget and rate refusals do not drop the authority connection")


# ----------------------------------------------------------------- restart

func _capture_before_stop(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The member rejoins to capture the persisted view")
	if client == null or not client.joined:
		return
	view_before_stop = _view(await _residents("resident-view-before-stop"))
	rows_before_stop = (view_before_stop.get("residents", []) as Array).duplicate(true)
	_expect(bool(view_before_stop.get("available", false)),
		"The view is available before the restart")
	_expect(rows_before_stop.size() == NpcRoster.IDS.size(),
		"The persisted view has one row per resident")


func _test_restart(codes: Dictionary, bytes_before_stop: PackedByteArray) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The member rejoins the restarted authority")
	if client == null or not client.joined:
		return
	var view: Dictionary = _view(await _residents("resident-view-restart"))
	_expect(bool(view.get("available", false)),
		"The restarted authority keeps residents enabled")
	_expect(JSON.stringify(view.get("residents", [])) \
			== JSON.stringify(rows_before_stop),
		"The resident view is identical after the restart")
	_expect(_bytes(_residents_path()) == bytes_before_stop,
		"The restart loads residents.json without rewriting it")


func _test_disabled(codes: Dictionary, bytes_before_stop: PackedByteArray) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The member joins the authority started without residents")
	if client == null or not client.joined:
		return
	var reply: Dictionary = await _residents("resident-view-disabled")
	var view: Dictionary = _view(reply)
	_expect(bool(reply.get("ok", false)),
		"The disabled authority still answers the read")
	_expect(not bool(view.get("available", true)),
		"An authority without --residents reports unavailable")
	_expect(str(view.get("reason", "")) == "disabled",
		"The disabled view names the disabled reason")
	_expect((view.get("residents", []) as Array).is_empty(),
		"The disabled view exposes no resident rows")
	_expect(_bytes(_residents_path()) == bytes_before_stop,
		"A disabled restart leaves residents.json byte-identical")


# ------------------------------------------------------------------ helpers

func _view(reply: Dictionary) -> Dictionary:
	var value: Variant = reply.get("state")
	return value if value is Dictionary else {}


func _row(rows: Array, npc_id: String) -> Dictionary:
	for row_value: Variant in rows:
		if row_value is Dictionary \
				and str((row_value as Dictionary).get("id", "")) == npc_id:
			return row_value
	return {}


func _purchased(rows: Array) -> bool:
	if rows.size() != NpcRoster.IDS.size():
		return false
	for row_value: Variant in rows:
		if not row_value is Dictionary:
			return false
		if int((row_value as Dictionary).get("intents_consumed", 0)) <= 0:
			return false
	return true


func _seed() -> int:
	if client == null or client.member == null:
		return -1
	var nature: Variant = client.member.snapshot.get("nature", {})
	if not nature is Dictionary:
		return -1
	return int((nature as Dictionary).get("seed", -1))


func _residents(request_id: String, action: String = "state") -> Dictionary:
	_residents_pending.erase(request_id)
	if client == null or not client.request_residents(request_id, action):
		return {"ok": false, "reason": "not_sent"}
	return await _residents_key(request_id, 15000)


func _residents_key(request_id: String, timeout_ms: int) -> Dictionary:
	var arrived: bool = await _wait(func() -> bool:
		return _residents_pending.has(request_id), timeout_ms)
	if not arrived:
		_expect(false, "A resident reply arrives for request %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _residents_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


func _has_reason(reason: String) -> bool:
	for payload_value: Variant in _residents_pending.values():
		if payload_value is Dictionary \
				and str((payload_value as Dictionary).get("reason", "")) == reason:
			return true
	return false


## Returns the first forbidden key found at any depth, or "".
func _forbidden_path(value: Variant) -> String:
	if value is Dictionary:
		for key: Variant in (value as Dictionary).keys():
			if str(key) in FORBIDDEN_KEYS:
				return str(key)
			var nested: String = _forbidden_path((value as Dictionary)[key])
			if not nested.is_empty():
				return nested
	elif value is Array:
		for item: Variant in value:
			var nested: String = _forbidden_path(item)
			if not nested.is_empty():
				return nested
	return ""


func _open_client(code: String, player_id: String, display_name: String,
		secret_text: String) -> bool:
	_ready = false
	_refusals.clear()
	_residents_pending.clear()
	_command_pending.clear()
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(_farm: RefCounted, _decorations: RefCounted,
			_now: float) -> void:
		_ready = true)
	client.refused.connect(func(reason: String) -> void: _refusals.append(reason))
	client.lost.connect(func(reason: String) -> void: _refusals.append(reason))
	client.residents_result.connect(_on_residents_result)
	client.committed.connect(_on_committed)
	var secret: PackedByteArray = Marshalls.base64_to_raw(secret_text) \
		if not player_id.is_empty() else PackedByteArray()
	if not client.start(code, player_id, display_name, secret):
		return false
	var arrived: bool = await _wait(func() -> bool:
		return (_ready and client.joined) or not _refusals.is_empty(), 20000)
	if not arrived or not _ready or not client.joined:
		_expect(false, "The client joins: refusals=%s" % str(_refusals))
		return false
	return true


func _close_client() -> void:
	if client != null:
		if is_instance_valid(client):
			client.close()
			client.queue_free()
		client = null
	_residents_pending.clear()
	_command_pending.clear()
	await process_frame
	await process_frame
	await create_timer(0.2).timeout


func _on_residents_result(request_id: String, payload: Dictionary) -> void:
	_residents_pending[request_id] = payload


func _on_committed(request_id: String, payload: Dictionary) -> void:
	_command_pending[request_id] = payload


func _submit(command: Dictionary) -> Dictionary:
	var request_id: String = str(command.get("id", ""))
	_command_pending.erase(request_id)
	if client == null or not client.submit(command):
		return {"ok": false, "reason": "not_sent"}
	var arrived: bool = await _wait(func() -> bool:
		return _command_pending.has(request_id), 20000)
	if not arrived:
		_expect(false, "A command reply arrives for %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _command_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


# ------------------------------------------------------------------- server

func _start_authority(host_player: String, now: float, residents: bool) -> bool:
	port = _free_port()
	_expect(port > 0, "A free loopback port is available")
	if port <= 0:
		return false
	url = "wss://127.0.0.1:%d" % port
	server_pid = _spawn_server(host_player, now, residents, "server.log")
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
	if OS.get_name() != "Windows":
		var ready: Dictionary = _server_line("server.log", "WORLD_SERVER_READY ")
		_expect(str(ready.get("state", "")) == "running",
			"The ready line reports the running state")
		_expect(bool(ready.get("residents", false)) == residents,
			"The ready line records the residents flag")
	var status: Dictionary = _status()
	_expect(str(status.get("host_player", "")) == host_player,
		"The status file records the host player")
	return true


func _spawn_server(host_player: String, now: float, residents: bool,
		log_name: String) -> int:
	var arguments := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % now, "--run-seconds=0", "--join-url=" + url,
		"--host-player=" + host_player,
	])
	if residents:
		arguments.append("--residents")
	if OS.get_name() == "Windows":
		return OS.create_process(OS.get_executable_path(), arguments, false)
	var pieces: PackedStringArray = []
	pieces.append(_shell_quote(OS.get_executable_path()))
	for argument: String in arguments:
		pieces.append(_shell_quote(argument))
	var command: String = "exec " + " ".join(pieces) + " > " \
		+ _shell_quote(dir.path_join(log_name)) + " 2>&1"
	return OS.create_process("/bin/sh", PackedStringArray(["-c", command]), false)


func _shell_quote(value: String) -> String:
	return "'" + value.replace("'", "'\\''") + "'"


func _server_line(log_name: String, prefix: String) -> Dictionary:
	var path: String = dir.path_join(log_name)
	if not FileAccess.file_exists(path):
		return {}
	for line: String in FileAccess.get_file_as_string(path).split("\n"):
		if line.begins_with(prefix):
			var parsed: Variant = JSON.parse_string(line.substr(prefix.length()))
			return parsed if parsed is Dictionary else {}
	return {}


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


func _residents_path() -> String:
	return world_dir.path_join("residents.json")


func _status() -> Dictionary:
	return _read_json(world_dir.path_join("server-status.json"))


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path) \
		if FileAccess.file_exists(path) else PackedByteArray()


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


func _wait(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


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
	print("RESIDENT_VIEW_NETWORK_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
