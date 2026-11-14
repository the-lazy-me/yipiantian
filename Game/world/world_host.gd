extends Node
## Authoritative shared-world host. Owns one HeadlessWorld, the invite secret and
## the authentication gate; member clients only submit commands.
##
## Two gates, in order: authentication proves the client holds the invite, then
## join checks that the client speaks the same protocol/rules versions and names
## the same world. A peer that fails either gate never reaches a command RPC.
## Every accepted command goes through HeadlessWorld.execute(), which persists
## through FarmStore before the result is returned.
##
## RPC routing is by node path, so this node and WorldMember must be added to
## the scene tree under the same name (see SESSION_NODE_NAME).

const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")

const PROTOCOL_VERSION: int = 1
const RULES_VERSION: int = 27
const MAX_PAYLOAD: int = 1024
const ROLE: String = "member"
const SESSION_NODE_NAME: String = "WorldSession"

signal member_joined(peer_id: int)
signal member_left(peer_id: int)
signal member_rejected(peer_id: int, reason: String)
signal command_committed(peer_id: int, payload: String)

var world: HeadlessWorld
var secret: PackedByteArray
var world_id: String = ""
var run_generation: int = 0
## Set while this authority is being retired. Members may still read, but no
## command is applied: an old server that keeps writing would fork the world
## even though the new server already carries a higher generation.
var read_only: bool = false

var _challenges: Dictionary = {}
var _members: Dictionary = {}


func configure(save_directory: String, now_utc: float, invite_secret: PackedByteArray,
		world_identity: String, generation: int = 1) -> Dictionary:
	secret = invite_secret
	world_id = world_identity
	run_generation = maxi(generation, 1)
	world = HeadlessWorld.new()
	var opened: Dictionary = world.open(save_directory, now_utc)
	if not opened.ok:
		return opened
	multiplayer.auth_callback = _authenticate
	multiplayer.peer_disconnected.connect(_forget)
	return opened


func is_member(peer_id: int) -> bool:
	return _members.has(peer_id)


func member_count() -> int:
	return _members.size()


func _defer_disconnect(peer_id: int, reason: String) -> void:
	_challenges.erase(peer_id)
	_members.erase(peer_id)
	member_rejected.emit(peer_id, reason)
	await get_tree().create_timer(0.5).timeout
	multiplayer.disconnect_peer(peer_id)


func reject(peer_id: int, reason: String) -> void:
	# Used by a host that refuses further joins (for example during migration).
	_challenges.erase(peer_id)
	_members.erase(peer_id)
	member_rejected.emit(peer_id, reason)
	multiplayer.disconnect_peer(peer_id)


## Begin authentication for a peer: the first message only opens a challenge.
func _authenticate(peer_id: int, data: PackedByteArray) -> void:
	if not _challenges.has(peer_id):
		_challenges[peer_id] = Crypto.new().generate_random_bytes(32)
		multiplayer.send_auth(peer_id, _challenges[peer_id])
		return
	var expected: PackedByteArray = Crypto.new().hmac_digest(
		HashingContext.HASH_SHA256, secret, _challenges[peer_id])
	if secret.is_empty() or not Crypto.new().constant_time_compare(expected, data):
		reject(peer_id, "bad_invite")
		return
	_challenges.erase(peer_id)
	multiplayer.complete_auth(peer_id)


func _forget(peer_id: int) -> void:
	_challenges.erase(peer_id)
	if _members.has(peer_id):
		_members.erase(peer_id)
		member_left.emit(peer_id)


@rpc("any_peer", "call_remote", "reliable", 0)
func join(payload: String) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	var parsed: Variant = JSON.parse_string(payload)
	var request: Dictionary = parsed if parsed is Dictionary else {}
	var reason: String = ""
	if _members.has(sender):
		reason = "already_joined"
	elif int(request.get("protocol_version", -1)) != PROTOCOL_VERSION:
		reason = "protocol_version"
	elif int(request.get("rules_version", -1)) != RULES_VERSION:
		reason = "rules_version"
	elif str(request.get("world_id", "")) != world_id:
		reason = "world_mismatch"
	if not reason.is_empty():
		_join_reply.rpc_id(sender, JSON.stringify({"ok": false, "reason": reason}))
		# Let the refusal reach the client before the socket closes; an immediate
		# disconnect would surface to the user as an unexplained dropped session.
		_defer_disconnect(sender, reason)
		return
	_members[sender] = ROLE
	_join_reply.rpc_id(sender, JSON.stringify({
		"ok": true, "role": ROLE, "world_id": world_id,
		"run_generation": run_generation, "protocol_version": PROTOCOL_VERSION,
		"rules_version": RULES_VERSION,
		"sequence": world.farm.event_sequence() if world.farm != null else 0,
	}))
	member_joined.emit(sender)


@rpc("authority", "call_remote", "reliable", 1)
func _join_reply(payload: String) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 2)
func command_result(request_id: String, payload: String) -> void:
	pass


@rpc("any_peer", "call_remote", "reliable", 3)
func submit(payload: String) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if not _members.has(sender):
		# Authentication and join already decide membership; this check means a
		# future RPC-ordering bug cannot quietly widen access.
		return
	if payload.length() > MAX_PAYLOAD:
		command_result.rpc_id(sender, "", JSON.stringify({"ok": false, "reason": "payload_too_large"}))
		return
	var parsed: Variant = JSON.parse_string(payload)
	var request: Dictionary = parsed if parsed is Dictionary else {}
	var request_id: String = str(request.get("request_id", ""))
	if request_id.is_empty() or request_id.length() > FarmCommand.MAX_ID_LENGTH:
		command_result.rpc_id(sender, request_id, JSON.stringify({"ok": false, "reason": "invalid_request"}))
		return
	var command: Dictionary = request.get("command", {}) as Dictionary
	if not FarmCommand.valid(command):
		command_result.rpc_id(sender, request_id, JSON.stringify({"ok": false, "reason": "invalid_command"}))
		return
	var result: Dictionary = execute_for_member(sender, command)
	command_result.rpc_id(sender, request_id, JSON.stringify(result))


## Executes one command and returns the reply payload. Split out so tests can
## drive the authority without a transport while sharing the exact same path.
func execute_for_member(_peer_id: int, command: Dictionary) -> Dictionary:
	if read_only:
		# Migration stops writes here. Refusing at the command entrance is the
		# only reliable stop: refusing new connections would leave this server
		# happily accepting commands from peers already connected.
		return {"ok": false, "reason": "read_only", "stage": "", "duplicate": false,
			"reward_crop_id": "", "reward_amount": 0,
			"sequence": world.farm.event_sequence() if world.farm != null else 0}
	var execution: Dictionary = world.execute(command)
	var reply := {
		"ok": bool(execution.get("ok", false)),
		"reason": str(execution.get("reason", "")),
		"stage": str(execution.get("stage", "")),
		"duplicate": bool(execution.get("duplicate", false)),
		"reward_crop_id": str(execution.get("reward_crop_id", "")),
		"reward_amount": int(execution.get("reward_amount", 0)),
		"sequence": world.farm.event_sequence() if world.farm != null else 0,
	}
	if reply.ok:
		command_committed.emit(_peer_id, JSON.stringify(command))
	return reply


@rpc("any_peer", "call_remote", "reliable", 4)
func request_summary() -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if not _members.has(sender):
		return
	var summary: Dictionary = world.summary()
	summary["world_id"] = world_id
	summary["run_generation"] = run_generation
	summary["role"] = _members[sender]
	command_result.rpc_id(sender, "summary", JSON.stringify(summary))


func identity() -> Dictionary:
	return {"world_id": world_id, "run_generation": run_generation}
