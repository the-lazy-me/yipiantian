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
const WorldInvite = preload("res://world/world_invite.gd")

signal joined(state: Dictionary)
signal join_failed(reason: String)
signal reply_received(request_id: String, payload: Dictionary)
signal authority_lost(reason: String)
## Another member's commit, applied on this client. Carries the same shape as a
## local reply so callers do not need two paths.
signal remote_change(payload: Dictionary)

const SESSION_NODE_NAME: String = "WorldSession"

var endpoint: String = ""
var world_id: String = ""
var protocol_version: int = 1
var rules_version: int = 27
var secret: PackedByteArray
var role: String = ""
## The invitation this member presents; empty means the raw `secret` is used.
var grant_id: String = ""
var last_sequence: int = 0
var run_generation: int = 0
var state: Dictionary = {}

var _joined: bool = false
var _pending: int = 0


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
	multiplayer.connected_to_server.connect(_on_session_ready)
	multiplayer.connection_failed.connect(func() -> void:
		authority_lost.emit("connection_failed"))
	multiplayer.server_disconnected.connect(func() -> void:
		_joined = false
		authority_lost.emit("server_disconnected"))


## Called once the transport reports an authenticated, complete session.
func _on_session_ready() -> void:
	join.rpc_id(1, JSON.stringify({
		"protocol_version": protocol_version, "rules_version": rules_version,
		"world_id": world_id,
	}))


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


## A commit made by another member, delivered on the shared reply channel.
func _apply_broadcast(entry: Dictionary) -> void:
	var sequence: int = int(entry.get("sequence", 0))
	# A sequence this client already applied is a duplicate delivery, not a new
	# change; a lower one means the sender is behind and must not rewind us.
	if sequence <= last_sequence:
		return
	last_sequence = sequence
	remote_change.emit(entry)


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


## The first auth message carries the grant id: the host answers with a challenge
## either way, so naming a grant reveals nothing about whether it exists.
func auth_hello() -> PackedByteArray:
	return grant_id.to_utf8_buffer()
