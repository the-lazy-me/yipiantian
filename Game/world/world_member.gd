extends Node
## Member side of a shared world. Presents the server-authoritative state and
## submits commands; it never writes a farm snapshot itself.
##
## Same gate order as the host: authenticate (invite), then join (protocol/rules
## versions + world identity). A reply that fails either gate leaves the client
## with no authority, so gameplay stays blocked rather than showing cached
## results as committed.

## RPC routing is by node path: this node must share WorldHost.SESSION_NODE_NAME.

const FarmCommand = preload("res://farm/farm_command.gd")
const FarmState = preload("res://farm/farm_state.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const NatureState = preload("res://farm/nature_state.gd")
const PlayerBindingState = preload("res://world/player_binding_state.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldProjection = preload("res://world/world_projection.gd")

signal joined(state: Dictionary)
signal join_failed(reason: String)
signal reply_received(request_id: String, payload: Dictionary)
signal authority_lost(reason: String)
## Another member's commit, applied on this client. Carries the same shape as a
## local reply so callers do not need two paths.
signal remote_change(payload: Dictionary)
## The answer to a social request, by request id.
signal social_result(request_id: String, payload: Dictionary)
## 权威对一次地籍请求的答复，按请求编号对应。载荷携带动作、地块、原因与
## 权威地籍视图；客户端不据此本地改归属，只用于提示和刷新。
signal territory_result(request_id: String, payload: Dictionary)
## 权威对一次组织请求的答复，按请求编号对应。答复只用于显示与刷新，客户端
## 不据此在本地改写成员或职位。
signal organization_result(request_id: String, payload: Dictionary)
## 权威对一次单位请求的答复，按请求编号对应。载荷携带动作、单位、原因与权威
## 单位视图；客户端不据此在本地改写名册。
signal unit_result(request_id: String, payload: Dictionary)
## 权威对一次公共基金请求的答复，按请求编号对应。载荷携带动作、基金、原因与
## 权威基金视图；客户端不据此在本地改现金或基金余额。
signal fund_result(request_id: String, payload: Dictionary)
signal participation_result(request_id: String, payload: Dictionary)
## A social event pushed by the authority (currently a message addressed to this
## player or to everyone), separate from request/answer traffic.
signal social_event(payload: Dictionary)
## 权威推送的完整成员名册。每次都是整份替换，订阅方无需自己合并增量。
signal roster_changed(rows: Array[Dictionary])

const SESSION_NODE_NAME: String = "WorldSession"

var endpoint: String = ""
var world_id: String = ""
var protocol_version: int = 1
var rules_version: int = 27
var secret: PackedByteArray
var role: String = ""
## The invitation this member presents; empty means the raw `secret` is used.
var grant_id: String = ""
## Stable player identity and mutable display name. Empty player_id means this
## client joins as an anonymous member with no social record.
var player_id: String = ""
var display_name: String = ""
## The 32-byte credential this installation owns. It stays local; the join
## carries a per-world HMAC proof derived from it. Empty for players without a
## profile, which leaves the join anonymous or refused.
var player_secret: PackedByteArray
## The last social view the authority sent for this player.
var social: Dictionary = {}
var last_sequence: int = 0
var run_generation: int = 0
var state: Dictionary = {}
## The authoritative documents carried by the last summary, or empty before one
## arrives. This is the whole world, not just the field view.
var snapshot: Dictionary = {}
## 当前世界内的成员名册；空表示尚未收到权威广播。整份替换，不做增量合并。
var roster: Array[Dictionary] = []

var _joined: bool = false
var _pending: int = 0
## 断线重连会重复调用 connect_to 复用同一个成员节点；SceneMultiplayer 的信号
## 只注册一次，否则每次尝试都会多一条断线/失败回调。
var _signals_connected: bool = false


## Connects presenting an invitation grant. The grant id travels in the first
## auth message so the host knows which secret to check; the secret itself never
## crosses the wire, only the HMAC answer does.
func connect_with_grant(address: String, grant: Dictionary, expected_world_id: String) -> void:
	var shape: Dictionary = WorldInvite.check_usable(grant, Time.get_unix_time_from_system(), 0)
	if not shape.ok:
		authority_lost.emit(str(shape.reason))
		return
	grant_id = str(grant.id)
	connect_to(address, grant.secret, expected_world_id)
	if str(grant.get("role", "")) != "":
		role = str(grant.role)


func connect_to(address: String, invite_secret: PackedByteArray, expected_world_id: String) -> void:
	endpoint = address
	secret = invite_secret
	world_id = expected_world_id
	if _signals_connected:
		return
	_signals_connected = true
	multiplayer.connected_to_server.connect(_on_session_ready)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _on_connection_failed() -> void:
	_joined = false
	authority_lost.emit("connection_failed")


func _on_server_disconnected() -> void:
	_joined = false
	authority_lost.emit("server_disconnected")


## Called once the transport reports an authenticated, complete session.
func _on_session_ready() -> void:
	join.rpc_id(1, JSON.stringify(join_payload()))


## The join document. It is a separate function so a fixture can assert what a
## named join actually sends without a live peer. `player_proof` is derived from
## the installation credential and the world id; the credential itself stays on
## this machine.
func join_payload() -> Dictionary:
	var payload: Dictionary = {
		"protocol_version": protocol_version, "rules_version": rules_version,
		"world_id": world_id,
	}
	if not player_id.is_empty():
		payload["player_id"] = player_id
		payload["display_name"] = display_name
		if not player_secret.is_empty():
			var proof: String = PlayerBindingState.proof(
				Marshalls.raw_to_base64(player_secret), world_id)
			if not proof.is_empty():
				payload["player_proof"] = proof
	return payload


@rpc("authority", "call_remote", "reliable", 1)
func _join_reply(payload: String) -> void:
	var parsed: Variant = JSON.parse_string(payload)
	var reply: Dictionary = parsed if parsed is Dictionary else {}
	if not bool(reply.get("ok", false)):
		join_failed.emit(str(reply.get("reason", "join_failed")))
		return
	if int(reply.get("protocol_version", -1)) != protocol_version:
		join_failed.emit("protocol_version")
		return
	if int(reply.get("rules_version", -1)) != rules_version:
		join_failed.emit("rules_version")
		return
	if str(reply.get("world_id", "")) != world_id:
		join_failed.emit("world_mismatch")
		return
	_joined = true
	run_generation = int(reply.get("run_generation", 0))
	last_sequence = int(reply.get("sequence", 0))
	role = str(reply.get("role", role))
	state = reply.duplicate(true)
	request_summary.rpc_id(1)
	joined.emit(state)


@rpc("any_peer", "call_remote", "reliable", 0)
func join(payload: String) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 2)
func command_result(request_id: String, payload: String) -> void:
	_pending = maxi(_pending - 1, 0)
	var parsed: Variant = JSON.parse_string(payload)
	var result: Dictionary = parsed if parsed is Dictionary else {}
	if request_id == "roster":
		# 同 change：名册是权威广播而不是本条请求的回复，不能套用下面的
		# 回复序号规则，也不发出 reply_received。
		_apply_roster(result)
		return
	if request_id == "change":
		# A broadcast is not a reply to this client's request, so the reply
		# sequence check below does not apply: an out-of-order broadcast is
		# dropped by _apply_broadcast instead of being read as a lost authority.
		_apply_broadcast(result)
		return
	var sequence: int = int(result.get("sequence", last_sequence))
	# A server sequence must never move backwards; a lower one means the reply
	# came from an older authority.
	if sequence < last_sequence:
		authority_lost.emit("stale_sequence")
		return
	last_sequence = sequence
	if request_id == "summary":
		state = result
		var carried: Variant = result.get("snapshot")
		snapshot = carried if carried is Dictionary else {}
		if result.has("role"):
			role = str(result.role)
		if int(result.get("run_generation", run_generation)) > run_generation:
			run_generation = int(result.run_generation)
	elif request_id == "catch_up":
		_apply_catch_up(result)
	reply_received.emit(request_id, result)


## Applies a catch-up reply. Events at or below `last_sequence` are already
## accounted for; applying them again would double-count a change, so only the
## genuinely missing ones are surfaced.
func _apply_catch_up(reply: Dictionary) -> void:
	if not bool(reply.get("ok", false)):
		# The tail aged out or the authority lost history; only a snapshot can
		# restore the true state, so ask for one instead of guessing.
		if str(reply.get("reason", "")) in ["tail_expired", "future_sequence"]:
			request_summary.rpc_id(1)
		return
	var highest: int = last_sequence
	for entry: Variant in reply.get("events", []):
		if not entry is Dictionary:
			continue
		var sequence: int = int(entry.get("sequence", 0))
		if sequence <= last_sequence:
			continue
		highest = maxi(highest, sequence)
		remote_change.emit(entry)
	last_sequence = highest


## Asks for the commits after the last sequence this client applied.
func request_catch_up() -> bool:
	if not _joined:
		return false
	catch_up.rpc_id(1, JSON.stringify({"since": last_sequence}))
	return true


## Rebuilds a usable local authority from the last summary. The payload crossed
## a network, so it passes the same validators a disk load does: a truncated or
## tampered document yields a named failure instead of a half-applied view.
func restore_state() -> Dictionary:
	var farm_data: Variant = snapshot.get("farm")
	var decoration_data: Variant = snapshot.get("decorations")
	var clock: Variant = snapshot.get("now_utc")
	if not farm_data is Dictionary or not decoration_data is Dictionary:
		return {"ok": false, "reason": "no_snapshot"}
	if not (clock is int or clock is float) or not is_finite(float(clock)) or float(clock) < 0.0:
		return {"ok": false, "reason": "invalid_time"}
	var farm := FarmState.new()
	# ADR-027: a projected document carries `view`. Its economy is a whitelist
	# view without a ledger, so it must be adopted by restore_view(); a document
	# without the marker is still a full authority snapshot (disk or fixture).
	var marker: Variant = snapshot.get("view")
	if marker is Dictionary:
		if int((marker as Dictionary).get("version", 0)) != WorldProjection.VIEW_VERSION:
			return {"ok": false, "reason": "view_version"}
		var viewer: String = str((marker as Dictionary).get("viewer", ""))
		# The projection is built for one connection. A mismatch means this
		# document belongs to someone else or was replayed out of context.
		if viewer != player_id:
			return {"ok": false, "reason": "view_mismatch"}
		if not farm.restore_view(farm_data, viewer):
			return {"ok": false, "reason": "invalid_farm"}
	elif not farm.restore_snapshot(farm_data):
		return {"ok": false, "reason": "invalid_farm"}
	var decorations := Decorations.new()
	if not decorations.restore_snapshot(decoration_data):
		return {"ok": false, "reason": "invalid_decorations"}
	# A summary from before nature existed carries none; the member then uses
	# the same fixed default seed rather than sampling a new one.
	var nature := NatureState.new()
	var nature_data: Variant = snapshot.get("nature")
	if nature_data != null:
		if not nature_data is Dictionary or not nature.restore_snapshot(nature_data):
			return {"ok": false, "reason": "invalid_nature"}
	# The member's local farm resolves the same weather blocks the authority
	# does, so derived growth and moisture views never disagree with a summary.
	farm.set_environment(nature)
	return {"ok": true, "reason": "", "farm": farm, "decorations": decorations,
		"nature": nature, "now_utc": float(clock)}


## A commit made by another member, delivered on the shared reply channel.
func _apply_broadcast(entry: Dictionary) -> void:
	var sequence: int = int(entry.get("sequence", 0))
	# A sequence this client already applied is a duplicate delivery, not a new
	# change; a lower one means the sender is behind and must not rewind us.
	if sequence <= last_sequence:
		return
	last_sequence = sequence
	remote_change.emit(entry)


## 整份替换名册。载荷来自网络，非字典的行被丢弃，而不是让类型化数组出错。
func _apply_roster(payload: Dictionary) -> void:
	var rows: Variant = payload.get("members")
	if not rows is Array:
		return
	var next: Array[Dictionary] = []
	for row: Variant in rows:
		if row is Dictionary:
			next.append(row as Dictionary)
	roster = next
	roster_changed.emit(roster)


@rpc("any_peer", "call_remote", "reliable", 6)
func catch_up(payload: String) -> void:
	pass


@rpc("any_peer", "call_remote", "reliable", 3)
func submit(payload: String) -> void:
	pass


@rpc("any_peer", "call_remote", "reliable", 4)
func request_summary() -> void:
	pass


## Submits a command only when this client currently has a joined authority.
## The command carries the sequence it was decided on, so the authority can
## refuse a command that no longer matches the state it was based on.
func submit_command(command: Dictionary) -> Dictionary:
	if not _joined:
		return {"ok": false, "reason": "not_joined"}
	if not FarmCommand.valid(command):
		return {"ok": false, "reason": "invalid_command"}
	var request_id: String = str(command.get("id", ""))
	submit.rpc_id(1, JSON.stringify({
		"request_id": request_id, "command": command,
		"based_on_sequence": last_sequence,
	}))
	_pending += 1
	return {"ok": true, "request_id": request_id}


func is_joined() -> bool:
	return _joined


## Sends one social operation. The authority answers through `social_result`;
## `state` operations carry the caller's whole view back.
func request_social(request_id: String, action: String, args: Dictionary = {}) -> bool:
	if not _joined:
		return false
	social_request.rpc_id(1, JSON.stringify({
		"request_id": request_id, "action": action, "args": args,
	}))
	return true


@rpc("authority", "call_remote", "reliable", 8)
func _social_reply(request_id: String, payload: String) -> void:
	var parsed: Variant = JSON.parse_string(payload)
	var result: Dictionary = parsed if parsed is Dictionary else {}
	if request_id == "event":
		social_event.emit(result)
		return
	var carried: Variant = result.get("state")
	if carried is Dictionary:
		social = carried
	social_result.emit(request_id, result)


@rpc("any_peer", "call_remote", "reliable", 7)
func social_request(payload: String) -> void:
	pass


## 提交一次地籍操作（主张/释放/转让）。动作与参数原样交给权威裁决，客户端
## 不判断归属或权限；未加入时返回 false，由调用方给出可见失败。
func request_territory(request_id: String, action: String, args: Dictionary = {}) -> bool:
	if not _joined:
		return false
	territory_request.rpc_id(1, JSON.stringify({
		"request_id": request_id, "action": action, "args": args,
	}))
	return true


@rpc("authority", "call_remote", "reliable", 10)
func _territory_reply(request_id: String, payload: String) -> void:
	var parsed: Variant = JSON.parse_string(payload)
	var result: Dictionary = parsed if parsed is Dictionary else {}
	territory_result.emit(request_id, result)


@rpc("any_peer", "call_remote", "reliable", 9)
func territory_request(payload: String) -> void:
	pass


## 提交一次组织操作（创建/加入/退出/任命/交接）。动作与参数原样交给权威裁决，
## 客户端不判断成员关系或职位；未加入时返回 false。
func request_organization(request_id: String, action: String,
		args: Dictionary = {}) -> bool:
	if not _joined:
		return false
	organization_request.rpc_id(1, JSON.stringify({
		"request_id": request_id, "action": action, "args": args,
	}))
	return true


@rpc("authority", "call_remote", "reliable", 12)
func _organization_reply(request_id: String, payload: String) -> void:
	var parsed: Variant = JSON.parse_string(payload)
	var result: Dictionary = parsed if parsed is Dictionary else {}
	organization_result.emit(request_id, result)


@rpc("any_peer", "call_remote", "reliable", 11)
func organization_request(payload: String) -> void:
	pass


## 提交一次单位操作（招募/解散/补给）。动作与参数原样交给权威裁决，客户端不判断
## 所有者或资源；未加入时返回 false。
func request_unit(request_id: String, action: String,
		args: Dictionary = {}) -> bool:
	if not _joined:
		return false
	unit_request.rpc_id(1, JSON.stringify({
		"request_id": request_id, "action": action, "args": args,
	}))
	return true


@rpc("authority", "call_remote", "reliable", 14)
func _unit_reply(request_id: String, payload: String) -> void:
	var parsed: Variant = JSON.parse_string(payload)
	var result: Dictionary = parsed if parsed is Dictionary else {}
	unit_result.emit(request_id, result)


@rpc("any_peer", "call_remote", "reliable", 13)
func unit_request(payload: String) -> void:
	pass


## 提交一次公共基金操作（开立/缴入/支出/换届）。动作与参数原样交给权威裁决，
## 客户端不判断组织权限或基金余额；未加入时返回 false。
func request_fund(request_id: String, action: String,
		args: Dictionary = {}) -> bool:
	if not _joined:
		return false
	fund_request.rpc_id(1, JSON.stringify({
		"request_id": request_id, "action": action, "args": args,
	}))
	return true


@rpc("authority", "call_remote", "reliable", 16)
func _fund_reply(request_id: String, payload: String) -> void:
	var parsed: Variant = JSON.parse_string(payload)
	var result: Dictionary = parsed if parsed is Dictionary else {}
	fund_result.emit(request_id, result)


@rpc("any_peer", "call_remote", "reliable", 15)
func fund_request(payload: String) -> void:
	pass


## 提交一次参与制度操作（声明规则/同意角色/退出）。动作与参数原样交给权威裁决，
## 客户端不判断房主身份、风险声明或上限；未加入时返回 false。
func request_participation(request_id: String, action: String,
		args: Dictionary = {}) -> bool:
	if not _joined:
		return false
	participation_request.rpc_id(1, JSON.stringify({
		"request_id": request_id, "action": action, "args": args,
	}))
	return true


@rpc("authority", "call_remote", "reliable", 18)
func _participation_reply(request_id: String, payload: String) -> void:
	var parsed: Variant = JSON.parse_string(payload)
	var result: Dictionary = parsed if parsed is Dictionary else {}
	participation_result.emit(request_id, result)


@rpc("any_peer", "call_remote", "reliable", 17)
func participation_request(payload: String) -> void:
	pass


## The first auth message carries the grant id: the host answers with a challenge
## either way, so naming a grant reveals nothing about whether it exists.
func auth_hello() -> PackedByteArray:
	return grant_id.to_utf8_buffer()
