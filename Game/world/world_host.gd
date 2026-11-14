extends Node
## Authoritative shared-world host. Owns one HeadlessWorld, the invitation
## grants and the authentication gate; member clients only submit commands.
##
## Two gates, in order: authentication proves the client holds an invitation,
## then join checks that the client speaks the same protocol/rules versions,
## names the same world, and that its grant may still be spent. A peer that
## fails either gate never reaches a command RPC.
## Every accepted command goes through HeadlessWorld.execute(), which persists
## through FarmStore before the result is returned.
##
## RPC routing is by node path, so this node and WorldMember must be added to
## the scene tree under the same name (see SESSION_NODE_NAME).

const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const SocialState = preload("res://social/social_state.gd")
const SocialStore = preload("res://social/social_store.gd")

const PROTOCOL_VERSION: int = 1
const RULES_VERSION: int = 27
const MAX_PAYLOAD: int = 1024
## How many recent commits a reconnecting member can catch up on without a full
## snapshot. Smaller than the on-disk ledger is deliberate: the tail is a
## convenience for reconnects, and the snapshot is the authority once it is gone.
const TAIL_LIMIT: int = 256
const SOCIAL_MAX_PAYLOAD: int = 2048
const SESSION_NODE_NAME: String = "WorldSession"

signal member_joined(peer_id: int)
signal member_left(peer_id: int)
signal member_rejected(peer_id: int, reason: String)
signal command_committed(peer_id: int, payload: String)

var world: HeadlessWorld
var world_id: String = ""
var run_generation: int = 0
## The social document the authority owns, and its storage boundary. Contacts and
## messages persist beside the farm save, so they can travel with it.
var social: Dictionary = {}
var social_store: SocialStore
## Set while this authority is being retired. Members may still read, but no
## command is applied: an old server that keeps writing would fork the world
## even though the new server already carries a higher generation.
var read_only: bool = false

var _grants: Dictionary = {}
var _challenges: Dictionary = {}
var _authenticated: Dictionary = {}
var _members: Dictionary = {}
var _member_grants: Dictionary = {}
## The stable player identity each session presented at join. A member without
## one can play but has no social record to act on.
var _players: Dictionary = {}
## Commits since this authority started, oldest first. `_tail_floor` is the first
## sequence still retained; a requester older than that must take a snapshot.
var _tail: Array = []
var _tail_floor: int = 0


func configure(save_directory: String, now_utc: float, world_identity: String,
		generation: int = 1) -> Dictionary:
	world_id = world_identity
	run_generation = maxi(generation, 1)
	world = HeadlessWorld.new()
	var opened: Dictionary = world.open(save_directory, now_utc)
	if not opened.ok:
		return opened
	# A corrupt social document must stop the authority instead of being ignored:
	# starting anyway would overwrite contacts and messages it could not read.
	social_store = SocialStore.new(save_directory)
	var social_loaded: Dictionary = social_store.load_state()
	if not social_loaded.ok:
		return {"ok": false, "reason": "social_" + str(social_loaded.kind)}
	social = social_loaded.state
	multiplayer.auth_callback = _authenticate
	multiplayer.peer_disconnected.connect(_forget)
	_tail.clear()
	_tail_floor = (world.farm.event_sequence() if world.farm != null else 0) + 1
	return opened


## Registers an invitation. Grants are independent: each carries its own role,
## expiry and use limit, so revoking one does not disturb the others.
func add_grant(grant: Dictionary) -> Dictionary:
	var shape: Dictionary = WorldInvite.check_usable(grant, _now(), 0)
	if not shape.ok and shape.reason != "invite_expired":
		return shape
	if str(grant.get("world_id", "")) != world_id:
		return {"ok": false, "reason": "world_mismatch"}
	_grants[str(grant.id)] = {"grant": grant, "uses": 0}
	return {"ok": true, "reason": ""}


func revoke_grant(grant_id: String) -> bool:
	var existed: bool = _grants.erase(grant_id)
	if not existed:
		return false
	# A revoked grant must also end the sessions it already opened; otherwise
	# revocation would only affect people who have not joined yet.
	var removed: bool = false
	for peer_id: int in _members.keys():
		if str(_member_grants.get(peer_id, "")) == grant_id:
			_members.erase(peer_id)
			_member_grants.erase(peer_id)
			member_left.emit(peer_id)
			removed = true
			multiplayer.disconnect_peer(peer_id)
	if removed:
		# 踢出的是已经在册的成员，剩余成员的名册必须立刻反映这次离开。
		_broadcast_roster()
	return true


## Grant summaries without the secrets, for an operator listing.
func grant_summary() -> Array:
	var rows: Array = []
	for grant_id: String in _grants:
		var entry: Dictionary = _grants[grant_id]
		var grant: Dictionary = entry.grant
		rows.append({
			"id": grant_id, "role": grant.role, "expires_at": grant.expires_at,
			"one_time": grant.one_time, "uses": int(entry.uses),
		})
	return rows


func member_role(peer_id: int) -> String:
	var grant_id: String = str(_member_grants.get(peer_id, ""))
	if not _grants.has(grant_id):
		return ""
	return str((_grants[grant_id] as Dictionary).grant.role)


func is_member(peer_id: int) -> bool:
	return _members.has(peer_id)


func member_count() -> int:
	return _members.size()


## 向所有成员广播完整名册，包括刚加入者。名册是整份替换而不是增量：
## 重连后重复收到同一份也不会重复出条目，新成员也不必另发一次请求。
func _broadcast_roster() -> void:
	var rows: Array = []
	for peer_id: int in _members.keys():
		# 匿名成员没有玩家标识，也不编造显示名：name 与 player_id 都留空。
		var player: Dictionary = _players.get(peer_id, {}) as Dictionary
		rows.append({
			"name": str(player.get("name", "")),
			"player_id": str(player.get("id", "")),
			"role": str(_members[peer_id]),
		})
	# 排序让相同成员集合产生逐字节相同的载荷，客户端可据此判断是同一份名册。
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if str(a.name) != str(b.name):
			return str(a.name) < str(b.name)
		if str(a.player_id) != str(b.player_id):
			return str(a.player_id) < str(b.player_id)
		return str(a.role) < str(b.role))
	var payload: String = JSON.stringify({"members": rows, "count": rows.size()})
	for peer_id: int in _members.keys():
		command_result.rpc_id(peer_id, "roster", payload)


func _defer_disconnect(peer_id: int, reason: String) -> void:
	_challenges.erase(peer_id)
	var left: bool = _members.has(peer_id)
	_members.erase(peer_id)
	_players.erase(peer_id)
	member_rejected.emit(peer_id, reason)
	if left:
		_broadcast_roster()
	await get_tree().create_timer(0.5).timeout
	multiplayer.disconnect_peer(peer_id)


func reject(peer_id: int, reason: String) -> void:
	# Used by a host that refuses further joins (for example during migration).
	_challenges.erase(peer_id)
	var left: bool = _members.has(peer_id)
	_members.erase(peer_id)
	_players.erase(peer_id)
	member_rejected.emit(peer_id, reason)
	if left:
		_broadcast_roster()
	multiplayer.disconnect_peer(peer_id)


## Begin authentication for a peer. The first message names the grant being
## presented; the host answers with a one-time challenge either way, so a peer
## cannot probe which grant ids exist by watching the response.
func _authenticate(peer_id: int, data: PackedByteArray) -> void:
	if not _challenges.has(peer_id):
		var presented: String = data.get_string_from_utf8().strip_edges()
		var challenge: PackedByteArray = Crypto.new().generate_random_bytes(32)
		_challenges[peer_id] = {"challenge": challenge, "grant_id": presented}
		multiplayer.send_auth(peer_id, challenge)
		return
	var entry: Dictionary = _challenges[peer_id]
	var grant_id: String = str(entry.grant_id)
	var secret: PackedByteArray = _grant_secret(grant_id)
	var expected: PackedByteArray = Crypto.new().hmac_digest(
		HashingContext.HASH_SHA256, secret, entry.challenge as PackedByteArray)
	if secret.is_empty() or not Crypto.new().constant_time_compare(expected, data):
		reject(peer_id, "bad_invite")
		return
	_challenges.erase(peer_id)
	# The peer is authenticated but not yet a member; join() decides whether this
	# grant may still be spent. Remember which grant it proved so a role can be
	# resolved after join and so revocation can reach the session.
	_authenticated[peer_id] = grant_id
	multiplayer.complete_auth(peer_id)


func _grant_secret(grant_id: String) -> PackedByteArray:
	if grant_id.is_empty() or not _grants.has(grant_id):
		return PackedByteArray()
	return (_grants[grant_id] as Dictionary).grant.secret


func _now() -> float:
	# The world's own clock is the authority for expiry: a client cannot move it
	# and an operator cannot forget to sync an expiry sweep.
	return world.now_utc if world != null else Time.get_unix_time_from_system()


func _forget(peer_id: int) -> void:
	_challenges.erase(peer_id)
	_authenticated.erase(peer_id)
	_players.erase(peer_id)
	if _members.has(peer_id):
		_members.erase(peer_id)
		_member_grants.erase(peer_id)
		member_left.emit(peer_id)
		_broadcast_roster()


@rpc("any_peer", "call_remote", "reliable", 0)
func join(payload: String) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	var parsed: Variant = JSON.parse_string(payload)
	var request: Dictionary = parsed if parsed is Dictionary else {}
	var reason: String = ""
	var role: String = ""
	var grant_id: String = str(_authenticated.get(sender, ""))
	if _members.has(sender):
		reason = "already_joined"
	elif grant_id.is_empty():
		# Without a proven grant there is nothing to spend; this means the join
		# arrived before authentication instead of after it.
		reason = "not_authenticated"
	elif int(request.get("protocol_version", -1)) != PROTOCOL_VERSION:
		reason = "protocol_version"
	elif int(request.get("rules_version", -1)) != RULES_VERSION:
		reason = "rules_version"
	elif str(request.get("world_id", "")) != world_id:
		reason = "world_mismatch"
	elif not _valid_player_claim(request):
		reason = "invalid_player"
	else:
		var spent: Dictionary = _spend(grant_id)
		if not spent.ok:
			reason = str(spent.reason)
		else:
			role = str(spent.role)
	if not reason.is_empty():
		_join_reply.rpc_id(sender, JSON.stringify({"ok": false, "reason": reason}))
		# Let the refusal reach the client before the socket closes; an immediate
		# disconnect would surface to the user as an unexplained dropped session.
		_defer_disconnect(sender, reason)
		return
	_authenticated.erase(sender)
	_members[sender] = role
	_member_grants[sender] = grant_id
	# A player id is optional: a member without one can tend the farm but cannot
	# use the social record, so an older client is not shut out.
	var player_id: String = str(request.get("player_id", ""))
	if not player_id.is_empty():
		_players[sender] = {"id": player_id, "name": str(request.get("display_name", ""))}
	_join_reply.rpc_id(sender, JSON.stringify({
		"ok": true, "role": role, "world_id": world_id,
		"run_generation": run_generation, "protocol_version": PROTOCOL_VERSION,
		"rules_version": RULES_VERSION,
		"sequence": world.farm.event_sequence() if world.farm != null else 0,
	}))
	member_joined.emit(sender)
	# 加入者同样需要这份名册（不同于变更广播跳过提交者）：它由此知道
	# 自己已经入册，且无需额外请求就能看到当前所有在线成员。
	_broadcast_roster()


## Spends one use of a grant, or refuses. A one-time grant is used up on join,
## not on authentication: proving the secret must not burn the code before the
## peer has shown it is a compatible client.
func _spend(grant_id: String) -> Dictionary:
	if not _grants.has(grant_id):
		return {"ok": false, "reason": "invite_revoked"}
	var entry: Dictionary = _grants[grant_id]
	var grant: Dictionary = entry.grant
	var usable: Dictionary = WorldInvite.check_usable(grant, _now(), int(entry.uses))
	if not usable.ok:
		return usable
	entry.uses = int(entry.uses) + 1
	# A spent one-time grant stays registered so a retry gets `invite_used`
	# rather than failing authentication as if the code never existed.
	return {"ok": true, "reason": "", "role": str(grant.role)}


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
	# An optional precondition: the client says which sequence it based the
	# command on. This is the only way to catch "I decided to act on a state that
	# has since changed" when the current rules would still accept the action.
	var basis: Variant = request.get("based_on_sequence")
	if not (basis is int or basis is float):
		command_result.rpc_id(sender, request_id,
			JSON.stringify({"ok": false, "reason": "missing_precondition", "stage": "", "duplicate": false,
				"reward_crop_id": "", "reward_amount": 0, "sequence": _sequence()}))
		return
	var stale: Dictionary = _check_precondition(command, int(basis))
	if not stale.is_empty():
		command_result.rpc_id(sender, request_id, JSON.stringify(stale))
		return
	var result: Dictionary = execute_for_member(sender, command)
	command_result.rpc_id(sender, request_id, JSON.stringify(result))


## Refuses a command whose stated basis is not the authority's current sequence.
## A retry of a committed id is exempt: its precondition was already satisfied
## when it was first accepted, and replay must stay idempotent.
func _check_precondition(command: Dictionary, basis: int) -> Dictionary:
	if FarmCommand.has_committed(world.farm, str(command.get("id", ""))):
		return {}
	var current: int = _sequence()
	if basis == current:
		return {}
	# Report both values: the client needs to know what to re-read, not just
	# that it lost. The failure is retriable, which is why it is not read_only.
	return {"ok": false, "reason": "stale_precondition", "stage": "", "duplicate": false,
		"reward_crop_id": "", "reward_amount": 0, "sequence": current,
		"expected_sequence": basis}


func _sequence() -> int:
	return world.farm.event_sequence() if world.farm != null else 0


## Executes one command and returns the reply payload. Split out so tests can
## drive the authority without a transport while sharing the exact same path.
func execute_for_member(peer_id: int, command: Dictionary) -> Dictionary:
	if read_only:
		# Migration stops writes here. Refusing at the command entrance is the
		# only reliable stop: refusing new connections would leave this server
		# happily accepting commands from peers already connected.
		return _refusal("read_only")
	# Permission is decided by the role the spent grant conferred, never by what
	# the client claims. A visitor that asks to harvest is refused here, before
	# the rules ever see the command. A collaboration grant the owner issued can
	# widen that role for named commands and fields, and is read on every command
	# so revocation constrains the very next one.
	var role: String = str(_members.get(peer_id, ""))
	if role.is_empty():
		return _refusal("not_a_member")
	var kind: String = str(command.get("kind", ""))
	if not WorldInvite.allows(role, kind) \
			and not _grant_allows(peer_id, kind, str(command.get("field_id", ""))):
		return _refusal("forbidden")
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
		command_committed.emit(peer_id, JSON.stringify(command))
		_append_tail(peer_id, command, reply)
	return reply


## Records one commit for catch-up. A duplicate replay is not a new event, so it
## never enters the tail: a member that reconnects must not see the same commit
## twice and apply it as new local state.
func _append_tail(peer_id: int, command: Dictionary, reply: Dictionary) -> void:
	if bool(reply.get("duplicate", false)):
		return
	var entry: Dictionary = {
		"sequence": int(reply.sequence), "command": command.duplicate(true),
		"stage": str(reply.stage), "reward_crop_id": str(reply.reward_crop_id),
		"reward_amount": int(reply.reward_amount),
	}
	_tail.append(entry)
	while _tail.size() > TAIL_LIMIT:
		_tail.remove_at(0)
		_tail_floor += 1
	# Everyone but the submitter learns about the commit; the submitter already
	# has its own reply and must not apply the same change twice. The change
	# travels on command_result so members need only one authority RPC.
	for other: int in _members.keys():
		if other != peer_id:
			command_result.rpc_id(other, "change", JSON.stringify(entry))


## The commits after `since`, or a reason the caller must take a snapshot.
## Bounded by TAIL_LIMIT so one request cannot ask for an unbounded reply.
func tail_since(since: int) -> Dictionary:
	var current: int = world.farm.event_sequence() if world.farm != null else 0
	if since > current:
		# A client claiming a future sequence is not behind; it is wrong, and
		# replaying a tail it never saw would paper over that.
		return {"ok": false, "reason": "future_sequence", "current": current, "events": []}
	if since + 1 < _tail_floor:
		# The requested point aged out of the retained tail; only a snapshot can
		# restore an authoritative state. `since == _tail_floor - 1` is still
		# complete: it asks for exactly the retained events.
		return {"ok": false, "reason": "tail_expired", "current": current,
			"floor": _tail_floor, "events": []}
	var events: Array = []
	for entry: Dictionary in _tail:
		if int(entry.sequence) > since:
			events.append(entry)
	return {"ok": true, "reason": "", "events": events, "current": current}


@rpc("any_peer", "call_remote", "reliable", 6)
func catch_up(payload: String) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if not _members.has(sender):
		return
	var parsed: Variant = JSON.parse_string(payload)
	var request: Dictionary = parsed if parsed is Dictionary else {}
	var since: Variant = request.get("since")
	if not (since is int or since is float):
		command_result.rpc_id(sender, "catch_up",
			JSON.stringify({"ok": false, "reason": "invalid_request"}))
		return
	var reply: Dictionary = tail_since(int(since))
	reply["request_id"] = "catch_up"
	command_result.rpc_id(sender, "catch_up", JSON.stringify(reply))


## A player id is a claim this authority accepts, not an account it verifies;
## the format and display name must still be sane, because both enter storage.
static func _valid_player_claim(request: Dictionary) -> bool:
	var player_id: Variant = request.get("player_id", "")
	if not player_id is String:
		return false
	if player_id.is_empty():
		return true
	return SocialState.valid_identifier(player_id) \
		and SocialState.valid_name(request.get("display_name", ""))


## One social operation. The candidate document is validated and persisted before
## it replaces the committed one, so a failed write never becomes the authority
## later operations build on.
func _apply_social(sender: int, action: String, args: Dictionary) -> Dictionary:
	var player: Dictionary = _players.get(sender, {}) as Dictionary
	if player.is_empty():
		return {"ok": false, "reason": "no_player"}
	if read_only:
		return {"ok": false, "reason": "read_only"}
	var viewer: String = str(player.id)
	var now: float = _now()
	var candidate: Dictionary = social.duplicate(true)
	var ensured: Dictionary = SocialState.ensure_player(candidate, viewer, str(player.name), now)
	if not ensured.ok:
		return ensured
	var target: String = str(args.get("player_id", ""))
	var result: Dictionary
	match action:
		"state":
			result = {"ok": true, "reason": ""}
		"invite":
			result = SocialState.invite(candidate, viewer, target, str(args.get("name", "")), now)
		"accept":
			result = SocialState.accept(candidate, viewer, target, now)
		"decline":
			result = SocialState.decline(candidate, viewer, target)
		"remove":
			result = SocialState.remove_contact(candidate, viewer, target)
		"block":
			result = SocialState.block(candidate, viewer, target, now, str(args.get("reason", "")))
		"unblock":
			result = SocialState.unblock(candidate, viewer, target)
		"send":
			result = SocialState.send(candidate, viewer, str(args.get("to", "")),
				SocialState.new_message_id(), str(args.get("text", "")), now)
		"grant":
			result = SocialState.grant(candidate, viewer, target,
				"grant_" + Crypto.new().generate_random_bytes(16).hex_encode(),
				_array_arg(args, "kinds"), _array_arg(args, "fields"),
				float(args.get("expires_at", 0.0)), now)
		"revoke":
			result = SocialState.revoke_grant(candidate, viewer, str(args.get("id", "")))
		"read":
			result = SocialState.mark_read(candidate, viewer, str(args.get("id", "")))
		"delete":
			result = SocialState.delete_message(candidate, viewer, str(args.get("id", "")))
		"visit":
			result = SocialState.record_visit(candidate, viewer, now)
		_:
			result = {"ok": false, "reason": "unknown_action"}
	if not result.ok:
		return result
	# A read that changed nothing does not rewrite the file; only a real change
	# has to pass the storage boundary first.
	if candidate != social:
		var saved: Dictionary = social_store.save_state(candidate)
		if not saved.ok:
			return {"ok": false, "reason": "save_" + str(saved.kind)}
		social = SocialState.canonical(candidate)
	if action == "send":
		_deliver_message(viewer, candidate.messages[candidate.messages.size() - 1])
	return {"ok": true, "reason": "", "state": SocialState.view(social, viewer)}


## A message reaches only a recipient who is online and not blocked. Offline
## players find it through the next `state` reply instead.
func _grant_allows(peer_id: int, kind: String, field_id: String) -> bool:
	var player_id: String = _player_id(peer_id)
	if player_id.is_empty():
		return false
	if not SocialState.allows(social, player_id, kind, field_id, _now()):
		return false
	# A grant naming fields must name real ones; an empty field list means the
	# whole farm, which is why it is validated here rather than in the document.
	if field_id.is_empty():
		return true
	return world != null and world.farm != null and world.farm.field_ids().has(field_id)


func _player_id(peer_id: int) -> String:
	var player: Dictionary = _players.get(peer_id, {}) as Dictionary
	return "" if player.is_empty() else str(player.id)


static func _array_arg(args: Dictionary, key: String) -> Array:
	var value: Variant = args.get(key, [])
	return value if value is Array else []


func _deliver_message(from_id: String, message: Dictionary) -> void:
	var payload: String = JSON.stringify({
		"event": "message",
		"message": {"id": message.id, "from": message.from,
			"from_name": SocialState.display_name(social, message.from),
			"to": message.to, "to_name": SocialState.display_name(social, message.to),
			"text": message.text, "at": message.at},
	})
	for peer_id: int in _members.keys():
		var player: Dictionary = _players.get(peer_id, {}) as Dictionary
		if player.is_empty():
			continue
		var id: String = str(player.id)
		if id == from_id:
			continue
		if not str(message.to).is_empty() and str(message.to) != id:
			continue
		_social_reply.rpc_id(peer_id, "event", payload)


@rpc("any_peer", "call_remote", "reliable", 7)
func social_request(payload: String) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if not _members.has(sender):
		return
	if payload.length() > SOCIAL_MAX_PAYLOAD:
		_social_reply.rpc_id(sender, "", JSON.stringify({"ok": false, "reason": "payload_too_large"}))
		return
	var parsed: Variant = JSON.parse_string(payload)
	var request: Dictionary = parsed if parsed is Dictionary else {}
	var request_id: String = str(request.get("request_id", ""))
	var args: Variant = request.get("args", {})
	if request_id.is_empty() or not args is Dictionary:
		_social_reply.rpc_id(sender, request_id, JSON.stringify({"ok": false, "reason": "invalid_request"}))
		return
	var reply: Dictionary = _apply_social(sender, str(request.get("action", "")), args)
	_social_reply.rpc_id(sender, request_id, JSON.stringify(reply))


@rpc("authority", "call_remote", "reliable", 8)
func _social_reply(request_id: String, payload: String) -> void:
	pass


func _refusal(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "stage": "", "duplicate": false,
		"reward_crop_id": "", "reward_amount": 0,
		"sequence": world.farm.event_sequence() if world.farm != null else 0}


@rpc("any_peer", "call_remote", "reliable", 4)
func request_summary() -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if not _members.has(sender):
		return
	var summary: Dictionary = world.summary()
	summary["world_id"] = world_id
	summary["run_generation"] = run_generation
	summary["role"] = _members[sender]
	# The view above is for display; this document is what a member restores
	# when the tail aged out. It is the same shape FarmStore writes, so the
	# client validates it through the existing restore paths.
	summary["snapshot"] = world.state_snapshot()
	command_result.rpc_id(sender, "summary", JSON.stringify(summary))


func identity() -> Dictionary:
	return {"world_id": world_id, "run_generation": run_generation}
