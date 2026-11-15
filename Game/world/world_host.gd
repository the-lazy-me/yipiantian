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
const PlayerBindingState = preload("res://world/player_binding_state.gd")
const PlayerBindingStore = preload("res://world/player_binding_store.gd")
const WorldPayload = preload("res://world/world_payload.gd")
const WorldProjection = preload("res://world/world_projection.gd")

const PROTOCOL_VERSION: int = 1
const RULES_VERSION: int = 27
const MAX_PAYLOAD: int = 1024
## How many recent commits a reconnecting member can catch up on without a full
## snapshot. Smaller than the on-disk ledger is deliberate: the tail is a
## convenience for reconnects, and the snapshot is the authority once it is gone.
const TAIL_LIMIT: int = 256
const SOCIAL_MAX_PAYLOAD: int = 2048
## 组织请求与答复共用 48 KiB 线上预算：请求本身很小，答复携带权威组织视图。
## 与其它权威文档一样，超预算必须在 rpc_id 之前换成可见拒绝。
const ORGANIZATION_MAX_PAYLOAD: int = WorldPayload.WIRE_BUDGET_BYTES
const SESSION_NODE_NAME: String = "WorldSession"

## 每个 peer 的令牌桶上限。三类请求分开计数，刷新摘要不会挤掉自己的命令额度。
## 默认值针对的是“一个成员反复触发权威工作”的放大路径：
##   - 命令：一次规则计算加一次 FarmStore 落盘；20 个突发足以覆盖现有夹具的
##     批量操作（M4 经济访客的 10 条拒绝扫描加前后命令），而持续 1 条/秒
##     让脚本循环无法把权威长期压在提交路径上。
##   - summary：整份世界序列化加 zstd 压缩；加入与重连会在 1 秒内各要一次，
##     30 秒的 reconcile 再要一次，5 个突发覆盖这些正常路径，之后 0.5 条/秒
##     把持续放大限制在每两秒一份。
##   - catch_up：回复最多 256 条事件并要按字节预算裁剪；重连通常只问一次，
##     4 个突发足够，之后 0.5 条/秒防止连续解析整段 tail。
## 桶只存在内存里，不写存档、不跨重启；断开时随 peer 一起清掉。
const RATE_COMMAND_BURST: int = 20
const RATE_COMMAND_REFILL_PER_SECOND: float = 1.0
const RATE_SUMMARY_BURST: int = 5
const RATE_SUMMARY_REFILL_PER_SECOND: float = 0.5
const RATE_CATCH_UP_BURST: int = 4
const RATE_CATCH_UP_REFILL_PER_SECOND: float = 0.5
const RATE_KIND_COMMAND: String = "command"
const RATE_KIND_SUMMARY: String = "summary"
const RATE_KIND_CATCH_UP: String = "catch_up"

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
## Player-id credentials: the first connection to claim an id binds it here and
## later connections must present the same secret. Empty before configure().
var player_bindings: Dictionary = {}
var player_binding_store: PlayerBindingStore
## The startup inputs, kept only so explicit social recovery can recreate the
## same authority after a damaged main document is restored from its backup.
var _save_directory: String = ""
var _startup_now_utc: float = 0.0
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
## Per-peer token buckets, keyed by peer then by RATE_KIND_*. In memory only:
## reconnecting or restarting always starts with the full burst.
var _rate: Dictionary = {}
## Commits since this authority started, oldest first. `_tail_floor` is the first
## sequence still retained; a requester older than that must take a snapshot.
var _tail: Array = []
var _tail_floor: int = 0
## Documents that could not fit the wire budget even after compression. Each one
## is counted and logged, and the peer receives a small visible refusal instead.
var payload_rejections: int = 0
## Requests refused by a peer's token bucket. Kept beside payload_rejections so
## an operator can tell "too big" from "too often" without reading warnings.
var rate_rejections: int = 0


func configure(save_directory: String, now_utc: float, world_identity: String,
		generation: int = 1) -> Dictionary:
	_save_directory = save_directory
	_startup_now_utc = now_utc
	world_id = world_identity
	run_generation = maxi(generation, 1)
	world = HeadlessWorld.new()
	var opened: Dictionary = world.open(save_directory, now_utc, world_identity)
	if not opened.ok:
		return opened
	# Economy commands, authority sweeps and a first build's implicit land claim
	# change documents other members cannot rebuild from a farm command alone.
	# The host answers the signal with the existing summary reply; no new message
	# type is defined.
	world.shared_changed.connect(_broadcast_summary)
	# A corrupt social document must stop the authority instead of being ignored:
	# starting anyway would overwrite contacts and messages it could not read.
	social_store = SocialStore.new(save_directory)
	var social_loaded: Dictionary = social_store.load_state()
	if not social_loaded.ok:
		return {"ok": false, "reason": "social_" + str(social_loaded.kind)}
	social = social_loaded.state
	# Expired grants and stale invitation rows are cleaned at load and at every
	# social action, so a full table cannot permanently block new consent. A
	# retired authority prunes in memory only: the document an operator copies is
	# the one the previous authority committed, so opening a read-only world
	# changes no byte on disk.
	var pruned: int = SocialState.prune(social, _now())
	if pruned > 0 and not read_only:
		var cleaned: Dictionary = social_store.save_state(social)
		if bool(cleaned.get("ok", false)):
			social = SocialState.canonical(social)
	# A corrupt binding document must stop the authority too: starting with an
	# empty registry would let any invite holder claim an existing identity.
	player_binding_store = PlayerBindingStore.new(save_directory)
	var bindings_loaded: Dictionary = player_binding_store.load_state()
	if not bindings_loaded.ok:
		return {"ok": false, "reason": "player_bindings_" + str(bindings_loaded.kind)}
	player_bindings = bindings_loaded.state
	multiplayer.auth_callback = _authenticate
	multiplayer.peer_disconnected.connect(_forget)
	_tail.clear()
	_tail_floor = (world.farm.event_sequence() if world.farm != null else 0) + 1
	return opened


## Explicit recovery: restore the previous committed social document, then
## finish opening the authority. Recovery is never automatic — a damaged main
## might be the only or newest copy — so a runner must ask for it by name.
func recover_social() -> Dictionary:
	if social_store == null:
		return {"ok": false, "reason": "not_configured"}
	if not social.is_empty():
		return {"ok": false, "reason": "already_open"}
	var recovered: Dictionary = social_store.recover()
	if not bool(recovered.get("ok", false)):
		return {"ok": false, "reason": "social_" + str(recovered.get("kind", "recovery_failed"))}
	var reopened: Dictionary = configure(_save_directory, _startup_now_utc, world_id, run_generation)
	if not bool(reopened.get("ok", false)):
		return reopened
	return {"ok": true, "reason": "", "kind": "social_recovered"}


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
			_rate.erase(peer_id)
			# The connection is gone, so its claimed id is free for a later session
			# with whatever grant that operator issues next.
			_players.erase(peer_id)
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
		var player_name: String = str(player.get("name", ""))
		var player_id: String = str(player.get("id", ""))
		rows.append({
			# The stored name is already disambiguated at registration when two
			# players chose the same label.
			"name": player_name,
			"player_id": player_id,
			"role": str(_members[peer_id]),
		})
	# 排序让相同成员集合产生逐字节相同的载荷，客户端可据此判断是同一份名册。
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if str(a.name) != str(b.name):
			return str(a.name) < str(b.name)
		if str(a.player_id) != str(b.player_id):
			return str(a.player_id) < str(b.player_id)
		return str(a.role) < str(b.role))
	var document: Dictionary = {"members": rows, "count": rows.size()}
	for peer_id: int in _members.keys():
		_send_payload(peer_id, "roster", document)


func _defer_disconnect(peer_id: int, reason: String) -> void:
	_challenges.erase(peer_id)
	_rate.erase(peer_id)
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
	_rate.erase(peer_id)
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
	# The server's own logical clock, not the growth clock: an empty or fully
	# mature world has no crop event to advance world.now_utc, but invitations,
	# social grants and expiry must still pass. Growth settlement is unchanged.
	if world != null:
		return world.authority_now_utc()
	return Time.get_unix_time_from_system()


## Public view of the clock used for invitation and social expiry, so a caller
## or a fixture can reason about the same instant without reaching into growth.
func clock_now() -> float:
	return _now()


func _forget(peer_id: int) -> void:
	_challenges.erase(peer_id)
	_authenticated.erase(peer_id)
	# A reconnect is a new connection: it must start with the full burst, not
	# inherit the previous session's exhausted bucket.
	_rate.erase(peer_id)
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
	elif _player_peer(str(request.get("player_id", ""))) != 0:
		# The id is only a claim, but two live sessions holding it would share
		# one bag, ledger account and social record. The first connection keeps
		# it; the second is refused instead of silently acting as that player.
		reason = "player_id_in_use"
	elif not str(request.get("player_id", "")).is_empty():
		# A named identity must present the same per-world proof it was first
		# bound with; an unbound id is bound on this join (trust on first use).
		var verified: Dictionary = _verify_player(
			str(request.get("player_id", "")), str(request.get("player_proof", "")))
		if not bool(verified.get("ok", false)):
			reason = str(verified.get("reason", "player_proof"))
	if reason.is_empty():
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
		var claimed_name: String = str(request.get("display_name", ""))
		_players[sender] = {"id": player_id, "name": claimed_name}
		# A display name is written when the player joins. Reads must never
		# rewrite the social document just because a local profile was renamed.
		# Registration makes duplicate names unique; the roster shows that form.
		var stored_name: String = _remember_social_player(player_id, claimed_name)
		if not stored_name.is_empty():
			_players[sender]["name"] = stored_name
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
		_send_payload(sender, "", {"ok": false, "reason": "payload_too_large",
			"reason_text": _reason_text("payload_too_large")})
		return
	var parsed: Variant = JSON.parse_string(payload)
	var request: Dictionary = parsed if parsed is Dictionary else {}
	var request_id: String = str(request.get("request_id", ""))
	# Both submit and social_request are member commands that can persist, so they
	# share the command bucket. A valid request id is echoed in the refusal so the
	# client can clear its pending entry instead of waiting for a timeout.
	var refusal_id: String = request_id if request_id.length() <= FarmCommand.MAX_ID_LENGTH else ""
	if not _admit(sender, RATE_KIND_COMMAND, refusal_id, false).is_empty():
		return
	if request_id.is_empty() or request_id.length() > FarmCommand.MAX_ID_LENGTH:
		_send_payload(sender, request_id, {"ok": false, "reason": "invalid_request",
			"reason_text": _reason_text("invalid_request")})
		return
	var command_value: Variant = request.get("command")
	# A hostile or buggy client can send any JSON type here. Keep the cast total:
	# an invalid value is a normal refusal, not a script error that can be
	# triggered repeatedly from the network.
	if not command_value is Dictionary:
		_send_payload(sender, request_id, {"ok": false, "reason": "invalid_command",
			"reason_text": _reason_text("invalid_command")})
		return
	var command: Dictionary = command_value
	if not FarmCommand.valid(command):
		_send_payload(sender, request_id, {"ok": false, "reason": "invalid_command",
			"reason_text": _reason_text("invalid_command")})
		return
	# An optional precondition: the client says which sequence it based the
	# command on. This is the only way to catch "I decided to act on a state that
	# has since changed" when the current rules would still accept the action.
	var basis: Variant = request.get("based_on_sequence")
	if not (basis is int or basis is float):
		_send_payload(sender, request_id,
			{"ok": false, "reason": "missing_precondition", "stage": "", "duplicate": false,
				"reward_crop_id": "", "reward_amount": 0, "sequence": _sequence()})
		return
	var stale: Dictionary = _check_precondition(command, int(basis))
	if not stale.is_empty():
		_send_payload(sender, request_id, stale)
		return
	var result: Dictionary = execute_for_member(sender, command)
	_send_payload(sender, request_id, result)


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
	return {"ok": false, "reason": "stale_precondition", "reason_text": _reason_text("stale_precondition"),
		"stage": "", "duplicate": false,
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
	var actor: String = _player_id(peer_id)
	if FarmCommand.is_economy_kind(kind):
		# Economic identity is the connection's player, never a claimed owner.
		# A social collaboration grant cannot widen this: it names farm work,
		# not money. Visitors therefore get no economy command at all, but keep
		# their water/weed farm permissions.
		if actor.is_empty():
			return _refusal("no_player")
		if not WorldInvite.allows(role, kind):
			return _refusal("forbidden")
	elif kind == FarmCommand.GIFT:
		# A gift is a social transfer between players, not work on the land, so a
		# named visitor may send one as recorded in M5. Anonymous members own no
		# bag and therefore cannot send or receive one.
		if actor.is_empty():
			return _refusal("no_player")
	elif kind == FarmCommand.SET_THEFT or kind == FarmCommand.BUILD \
			or kind == FarmCommand.DEMOLISH:
		# These change the player's own standing or a home that needs an owner.
		# They are member permissions, not farm-tending permissions: a named
		# visitor may weed or water but cannot build, demolish or change theft.
		if actor.is_empty():
			return _refusal("no_player")
		if not WorldInvite.allows(role, kind):
			return _refusal("forbidden")
	elif not WorldInvite.allows(role, kind) \
			and not _grant_allows(peer_id, kind, str(command.get("field_id", "")),
				str(command.get("cell_id", ""))):
		return _refusal("forbidden")
	# R16: one installation owns one per-world credential (ADR-029), but a join
	# may still bind a fresh `player_id` to that same credential. The opening
	# grant is issued per member, not per id string, so a new id whose proof is
	# already represented by a granted sibling must not mint a second grant.
	# A committed id is exempt: its retry is a replay, not a new issuance.
	if kind == FarmCommand.ACCOUNT_OPEN and world != null and world.farm != null \
			and not FarmCommand.has_committed(world.farm, str(command.get("id", ""))) \
			and _grant_held_by_another_id(actor):
		return _refusal("grant_already_issued")
	if kind == FarmCommand.HARVEST:
		# The owner's grant is resolved here, from the record, and stamped on the
		# command every member replays; a client cannot claim it for itself.
		command = command.duplicate(true)
		command["authorized"] = _grant_allows(peer_id, kind,
			str(command.get("field_id", "")), str(command.get("cell_id", "")))
	var execution: Dictionary = world.execute(command, actor)
	var reply := {
		"ok": bool(execution.get("ok", false)),
		"reason": str(execution.get("reason", "")),
		"stage": str(execution.get("stage", "")),
		"duplicate": bool(execution.get("duplicate", false)),
		"reward_crop_id": str(execution.get("reward_crop_id", "")),
		"reward_amount": int(execution.get("reward_amount", 0)),
		"sequence": world.farm.event_sequence() if world.farm != null else 0,
		"market_expired": int(execution.get("market_expired", 0)),
		"market_matched": int(execution.get("market_matched", 0)),
		"market_delivered": int(execution.get("market_delivered", 0)),
		"market_lost": int(execution.get("market_lost", 0)),
		"loans_settled": int(execution.get("loans_settled", 0)),
	}
	if not bool(reply.ok):
		# A machine reason stays available for replay and tests; the sender also
		# gets one human-readable Chinese line it can show without a lookup.
		reply["reason_text"] = _reason_text(str(reply.reason))
		# `not_owner` means "someone else's order" to the economy and "someone
		# else's house" to a demolish; only the latter needs its own wording.
		if kind == FarmCommand.DEMOLISH and str(reply.reason) == "not_owner":
			reply["reason_text"] = "只有房主能拆除这座建筑。"
	# The sender's own balance, so a client can show "my harvest" without being
	# granted every other member's bag. Anonymous members have none.
	if not actor.is_empty() and world.farm != null:
		reply["bags"] = world.farm.bag(actor)
	if kind == FarmCommand.HARVEST:
		# The sender replays the command it sent; tell it whether the grant was in
		# force so its local copy reaches the same verdict as the authority.
		reply["authorized"] = bool(command.get("authorized", false))
	if reply.ok:
		command_committed.emit(peer_id, JSON.stringify(command))
		_append_tail(peer_id, command, reply)
	return reply


## One cadastre operation from a connected member. The actor is always the player
## id this connection joined with, never a client-supplied owner, so a member
## cannot act as someone else. Reading is open to every member (including
## visitors and anonymous ones); only a named member may change land, which makes
## a visitor read-only by construction.
func territory_for_member(peer_id: int, action: String, args: Dictionary) -> Dictionary:
	if world == null:
		return _territory_refusal("not_open")
	if not _members.has(peer_id):
		return _territory_refusal("not_a_member")
	if action == "state":
		return {"ok": true, "reason": "", "action": "state",
			"state": world.territory_view()}
	if str(_members.get(peer_id, "")) != WorldInvite.MEMBER:
		return _territory_refusal("forbidden")
	if read_only:
		return _territory_refusal("read_only")
	var actor: String = _player_id(peer_id)
	if actor.is_empty():
		return _territory_refusal("no_player")
	var parcel_id: String = str(args.get("parcel_id", ""))
	var command_id: String = str(args.get("command_id", ""))
	var result: Dictionary
	match action:
		"claim":
			result = world.claim_territory(parcel_id, actor, command_id)
		"transfer":
			result = world.transfer_territory(parcel_id, actor,
				str(args.get("player_id", "")), command_id)
		"release":
			result = world.release_territory(parcel_id, actor, command_id)
		_:
			return _territory_refusal("unknown_action")
	result["action"] = action
	if not bool(result.get("ok", false)):
		result["reason_text"] = _territory_reason_text(str(result.get("reason", "")))
	return result


## 一次组织操作。操作者恒为本连接加入时声明的玩家 id，绝不读取载荷里的
## actor/owner；载荷的 player_id 只在 appoint/transfer 里表示目标成员。读取
## 对成员开放（含访客与匿名成员），写入要求成员角色与具名玩家身份。
func organization_for_member(peer_id: int, action: String, args: Dictionary) -> Dictionary:
	if world == null:
		return _with_organization_state(_organization_refusal("not_open"))
	if not _members.has(peer_id):
		return _with_organization_state(_organization_refusal("not_a_member"))
	if action == "state":
		return {"ok": true, "reason": "", "action": "state",
			"org_id": "", "duplicate": false, "state": world.organizations_view()}
	if str(_members.get(peer_id, "")) != WorldInvite.MEMBER:
		return _with_organization_state(_organization_refusal("forbidden"))
	if read_only:
		return _with_organization_state(_organization_refusal("read_only"))
	var actor: String = _player_id(peer_id)
	if actor.is_empty():
		return _with_organization_state(_organization_refusal("no_player"))
	if action != "create" and action != "join" and action != "leave" \
			and action != "appoint" and action != "transfer_leadership":
		return _with_organization_state(_organization_refusal("unknown_action"))
	var result: Dictionary = world.execute_organization(action, actor, args,
		str(args.get("command_id", "")))
	result["action"] = action
	if not bool(result.get("ok", false)):
		result["reason_text"] = _organization_reason_text(str(result.get("reason", "")))
	return _with_organization_state(result)


## 每个成员可见的组织答复都携带权威视图，直接调用与网络答复因此形状一致。
func _with_organization_state(reply: Dictionary) -> Dictionary:
	reply["state"] = _organization_state()
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
		# Who did it. A neighbour can see the action as a person's, not as an
		# anonymous state change; an anonymous member simply has no name.
		"from_id": str((_players.get(peer_id, {}) as Dictionary).get("id", "")),
		"from_name": str((_players.get(peer_id, {}) as Dictionary).get("name", "")),
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
			# ADR-027: each recipient gets its own projection. An economy command
			# becomes an opaque sequence marker; a non-economy command keeps its
			# full body so neighbours can replay it.
			_send_payload(other, "change",
				WorldProjection.project_change(entry, _player_id(other)))


## The commits after `since`, or a reason the caller must take a snapshot.
## Bounded by TAIL_LIMIT so one request cannot ask for an unbounded reply.
func tail_since(since: int, viewer: String = "") -> Dictionary:
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
			# Project before measuring: the 48 KiB budget must be computed from
			# the bytes this peer will actually receive, and the projection is
			# the only place an economy payload can be removed.
			events.append(WorldProjection.project_change(entry, viewer))
	# Measure the reply as catch_up() sends it, including the fixed request id.
	var reply: Dictionary = {"ok": true, "reason": "", "events": events,
		"current": current, "request_id": "catch_up"}
	if WorldPayload.fits(JSON.stringify(reply)):
		return reply
	# Compression still cannot carry the whole window. Find the longest newest
	# suffix that fits, only to name the floor a client would need after a
	# snapshot: dropping the oldest events leaves a hole, so a suffix can never
	# be returned as a successful catch-up.
	var low: int = 0
	var high: int = events.size()
	while low < high:
		var middle: int = (low + high + 1) / 2
		var suffix: Array = events.slice(events.size() - middle, events.size())
		if WorldPayload.fits(JSON.stringify({"ok": true, "reason": "",
				"events": suffix, "current": current, "request_id": "catch_up"})):
			low = middle
		else:
			high = middle - 1
	var floor: int = current + 1
	if low > 0:
		floor = int((events[events.size() - low] as Dictionary).sequence)
	return {"ok": false, "reason": "tail_expired", "current": current,
		"floor": floor, "events": []}


@rpc("any_peer", "call_remote", "reliable", 6)
func catch_up(payload: String) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if not _members.has(sender):
		return
	# The reply is at most TAIL_LIMIT events but still costs a full slice, budget
	# check and (usually) compression. The request id this channel answers with is
	# fixed, so the refusal can use it directly.
	if not _admit(sender, RATE_KIND_CATCH_UP, "catch_up", false).is_empty():
		return
	var parsed: Variant = JSON.parse_string(payload)
	var request: Dictionary = parsed if parsed is Dictionary else {}
	var since: Variant = request.get("since")
	if not (since is int or since is float):
		_send_payload(sender, "catch_up", {"ok": false, "reason": "invalid_request"})
		return
	var reply: Dictionary = tail_since(int(since), _player_id(sender))
	reply["request_id"] = "catch_up"
	_send_payload(sender, "catch_up", reply)


## A player id is a claim this authority accepts, not an account it verifies;
## the format and display name must still be sane, because both enter storage.
static func _valid_player_claim(request: Dictionary) -> bool:
	var player_id: Variant = request.get("player_id", "")
	if not player_id is String:
		return false
	if player_id.is_empty():
		return true
	return SocialState.valid_identifier(player_id) \
		and SocialState.valid_name(request.get("display_name", "")) \
		and PlayerBindingState.valid_secret(request.get("player_proof", ""))


## Verifies a named identity, binding it on first use. `proof_text` is the
## world-scoped proof the client derived from its local credential, never the
## credential itself. A read-only authority can check known ids but must not
## write, so an unknown id joins unbound: the next writable authority binds it
## on that player's first join.
func _verify_player(player_id: String, proof_text: String) -> Dictionary:
	var players: Variant = player_bindings.get("players")
	if players is Dictionary and (players as Dictionary).has(player_id):
		if PlayerBindingState.matches((players as Dictionary)[player_id], proof_text):
			return {"ok": true, "reason": ""}
		return {"ok": false, "reason": "player_proof"}
	if read_only:
		return {"ok": true, "reason": ""}
	if player_binding_store == null:
		return {"ok": false, "reason": "player_bindings_unavailable"}
	var candidate: Dictionary = PlayerBindingState.bind(player_bindings, player_id,
		proof_text, _now())
	if not bool(candidate.get("ok", false)):
		return {"ok": false, "reason": "player_" + str(candidate.get("reason", "invalid_secret"))}
	var saved: Dictionary = player_binding_store.save_state(candidate.state)
	if not saved.ok:
		return {"ok": false, "reason": "save_player_bindings_" + str(saved.kind)}
	player_bindings = candidate.state
	return {"ok": true, "reason": ""}


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
	# Clean stale rows at the action boundary. Expired grants free their slots;
	# fully deleted messages are reclaimed; unaccepted invitation rows expire.
	var keep: Array[String] = []
	for peer_id: int in _players.keys():
		var online: String = str((_players[peer_id] as Dictionary).get("id", ""))
		if not online.is_empty():
			keep.append(online)
	SocialState.prune(candidate, now, keep)
	# A read only registers the caller if it is new; it never renames an existing
	# record. A real write refreshes the label, and join writes it up front.
	var ensured: Dictionary
	if action == "state":
		ensured = SocialState.register_player(candidate, viewer, str(player.name), now)
	else:
		ensured = SocialState.ensure_player(candidate, viewer, str(player.name), now)
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
			# Only a member (the farm-owner role) may hand out land work. A
			# visitor cannot manufacture consent for a crop it does not own.
			if str(_members.get(sender, "")) != WorldInvite.MEMBER:
				result = {"ok": false, "reason": "forbidden"}
			elif not _grant_fields_claimable(viewer, _array_arg(args, "fields")):
				result = {"ok": false, "reason": "invalid_grant"}
			else:
				var expiry: Variant = args.get("expires_at", 0.0)
				# JSON null/array/object must be a named refusal, not a script error
				# raised by float() on a non-numeric payload.
				if not (expiry is int or expiry is float) or not is_finite(float(expiry)):
					result = {"ok": false, "reason": "invalid_grant"}
				else:
					result = SocialState.grant(candidate, viewer, target,
						"grant_" + Crypto.new().generate_random_bytes(16).hex_encode(),
						_array_arg(args, "kinds"), _array_arg(args, "fields"),
						float(expiry), now)
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
	return {"ok": true, "reason": "", "state": SocialState.view(social, viewer),
		"theft": world != null and world.farm != null and world.farm.theft_enabled(viewer)}


## A named field must exist and the issuer must already have a crop in it.
## An empty list is resolved per cell against the issuer, so it can only cover
## the issuer's own cells; naming another player's field is refused up front.
func _grant_fields_claimable(player_id: String, fields: Array) -> bool:
	if fields.is_empty():
		return true
	if world == null or world.farm == null:
		return false
	for value: Variant in fields:
		if not value is String:
			return false
		var field_id: String = value
		if not world.farm.field_ids().has(field_id):
			return false
		var owns: bool = false
		for cell_id: String in world.farm.cell_ids(field_id):
			if world.farm.owner_of(field_id, cell_id) == player_id:
				owns = true
				break
		if not owns:
			return false
	return true


## The issuer's grant is resolved from the document on every command. For
## harvest the grant's issuer must be the cell's real owner (`planted_by`), so a
## third party's grant can never authorize taking that crop.
func _grant_allows(peer_id: int, kind: String, field_id: String, cell_id: String = "") -> bool:
	var player_id: String = _player_id(peer_id)
	if player_id.is_empty():
		return false
	var owner_id: String = ""
	if kind == FarmCommand.HARVEST:
		if world == null or world.farm == null or field_id.is_empty() or cell_id.is_empty():
			return false
		owner_id = world.farm.owner_of(field_id, cell_id)
		# Nobody planted this cell, so nobody can consent for it. Harvesting it is
		# not theft anyway; a grant simply never applies.
		if owner_id.is_empty():
			return false
	if not SocialState.allows(social, player_id, kind, field_id, _now(), owner_id):
		return false
	# A grant naming fields must name real ones; an empty field list is scoped to
	# the issuer's own cells by the owner check above.
	if field_id.is_empty():
		return true
	return world != null and world.farm != null and world.farm.field_ids().has(field_id)


func _player_id(peer_id: int) -> String:
	var player: Dictionary = _players.get(peer_id, {}) as Dictionary
	return "" if player.is_empty() else str(player.id)


## R16 grant half. The binding document is the authority's evidence that two
## `player_id`s belong to the same member: a fresh id is bound to the proof the
## installation presented, so ids sharing one proof are aliases of each other.
## If any alias already holds the durable `granted` marker, this id must not
## receive the one-time opening grant again. The actor's own account is left to
## the economy rule (`already_granted`); only a granted sibling is new evidence.
## Nothing is written: both documents already exist and survive a restart.
func _grant_held_by_another_id(actor: String) -> bool:
	if actor.is_empty() or player_bindings.is_empty() or world == null or world.farm == null:
		return false
	var players: Variant = player_bindings.get("players")
	if not players is Dictionary:
		return false
	var registry: Dictionary = players
	var mine: Variant = registry.get(actor)
	if not mine is Dictionary:
		return false
	var proof: String = str((mine as Dictionary).get(PlayerBindingState.SECRET_FIELD, ""))
	if proof.is_empty() or world.farm.economy_granted(actor):
		return false
	for other: Variant in registry:
		var other_id: String = str(other)
		if other_id == actor:
			continue
		if PlayerBindingState.matches(registry[other], proof) \
				and world.farm.economy_granted(other_id):
			return true
	return false


## Persists the name a player presented at join and returns the label the roster
## should show (the stored, disambiguated form). Failure is not fatal: the session
## still plays, and the next successful social write retries the label.
func _remember_social_player(player_id: String, name: String) -> String:
	if social_store == null or name.is_empty():
		return name
	# A retired authority serves reads only; recording a join would write the very
	# document an operator is copying, and the next writable authority records it.
	if read_only:
		return name
	var candidate: Dictionary = social.duplicate(true)
	if not SocialState.ensure_player(candidate, player_id, name, _now()).ok:
		return name
	if candidate != social:
		if not bool(social_store.save_state(candidate).get("ok", false)):
			return SocialState.display_name(social, player_id)
		social = SocialState.canonical(candidate)
	var stored: String = SocialState.display_name(social, player_id)
	return name if stored.is_empty() else stored


## The active member currently holding `player_id`, or 0. Only members count:
## a rejected or disconnected session releases the id as soon as it leaves
## `_members`, so a reconnect can claim it again.
func _player_peer(player_id: String) -> int:
	if player_id.is_empty():
		return 0
	for peer_id: int in _members.keys():
		var player: Dictionary = _players.get(peer_id, {}) as Dictionary
		if str(player.get("id", "")) == player_id:
			return peer_id
	return 0


static func _array_arg(args: Dictionary, key: String) -> Array:
	var value: Variant = args.get(key, [])
	return value if value is Array else []


## A message reaches only a recipient who is online and not blocked. Offline
## players find it through the next `state` reply instead. The same block check
## applies to public messages: a broadcast is stored for everyone, but a live
## push never reaches a player in a blocked relationship with its sender.
func _deliver_message(from_id: String, message: Dictionary) -> void:
	var document: Dictionary = {
		"event": "message",
		"message": {"id": message.id, "from": message.from,
			"from_name": SocialState.display_name(social, message.from),
			"to": message.to, "to_name": SocialState.display_name(social, message.to),
			"text": message.text, "at": message.at},
	}
	for peer_id: int in _members.keys():
		var player: Dictionary = _players.get(peer_id, {}) as Dictionary
		if player.is_empty():
			continue
		var id: String = str(player.id)
		if id == from_id:
			continue
		if not str(message.to).is_empty() and str(message.to) != id:
			continue
		if SocialState.blocked(social, from_id, id):
			continue
		_send_social(peer_id, "event", document)


@rpc("any_peer", "call_remote", "reliable", 7)
func social_request(payload: String) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if not _members.has(sender):
		return
	if payload.length() > SOCIAL_MAX_PAYLOAD:
		_send_social(sender, "", {"ok": false, "reason": "payload_too_large"})
		return
	var parsed: Variant = JSON.parse_string(payload)
	var request: Dictionary = parsed if parsed is Dictionary else {}
	var request_id: String = str(request.get("request_id", ""))
	var args: Variant = request.get("args", {})
	var refusal_id: String = request_id if request_id.length() <= FarmCommand.MAX_ID_LENGTH else ""
	if not _admit(sender, RATE_KIND_COMMAND, refusal_id, true).is_empty():
		return
	if request_id.is_empty() or not args is Dictionary:
		_send_social(sender, request_id, {"ok": false, "reason": "invalid_request"})
		return
	var reply: Dictionary = _apply_social(sender, str(request.get("action", "")), args)
	_send_social(sender, request_id, reply)


@rpc("authority", "call_remote", "reliable", 8)
func _social_reply(request_id: String, payload: String) -> void:
	pass


## 一次地籍请求。动作与参数交给 `territory_for_member()`，它继续负责“谁是
## 操作者”和角色门；这里只做载荷、限频与回复封装。成功后广播一份新摘要，
## 让所有成员看到新的归属，而不依赖提交者本地回放。
@rpc("any_peer", "call_remote", "reliable", 9)
func territory_request(payload: String) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if not _members.has(sender):
		return
	if payload.length() > MAX_PAYLOAD:
		_send_territory(sender, "", {"ok": false, "action": "", "parcel_id": "",
			"reason": "payload_too_large", "reason_text": _reason_text("payload_too_large"),
			"state": _territory_state()})
		return
	var parsed: Variant = JSON.parse_string(payload)
	var request: Dictionary = parsed if parsed is Dictionary else {}
	var request_id: String = str(request.get("request_id", ""))
	var action: String = str(request.get("action", ""))
	var args_value: Variant = request.get("args", {})
	var refusal_id: String = request_id if request_id.length() <= FarmCommand.MAX_ID_LENGTH else ""
	# 土地操作会持久化，与 submit/social 共用命令令牌桶。
	if not _admit(sender, RATE_KIND_COMMAND, refusal_id, false, true).is_empty():
		return
	if request_id.is_empty() or not args_value is Dictionary:
		_send_territory(sender, request_id, {"ok": false, "action": action, "parcel_id": "",
			"reason": "invalid_request", "reason_text": _reason_text("invalid_request"),
			"state": _territory_state()})
		return
	var args: Dictionary = args_value as Dictionary
	var reply: Dictionary = territory_for_member(sender, action, args)
	var document: Dictionary = {
		"ok": bool(reply.get("ok", false)),
		"action": action,
		"parcel_id": str(reply.get("parcel_id", args.get("parcel_id", ""))),
		"reason": str(reply.get("reason", "")),
		"reason_text": str(reply.get("reason_text", "")),
		"state": _territory_state(),
	}
	_send_territory(sender, request_id, document)
	if bool(document.ok) and action in ["claim", "release", "transfer"]:
		_broadcast_summary()


@rpc("authority", "call_remote", "reliable", 10)
func _territory_reply(request_id: String, payload: String) -> void:
	pass


## 一次组织请求。动作与参数交给 `organization_for_member()`；这里只负责载荷、
## 限频和回复封装。答复始终随附权威组织视图，供客户端刷新显示。
@rpc("any_peer", "call_remote", "reliable", 11)
func organization_request(payload: String) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if not _members.has(sender):
		return
	if payload.to_utf8_buffer().size() > ORGANIZATION_MAX_PAYLOAD:
		_send_organization(sender, "", {"ok": false, "action": "", "org_id": "",
			"duplicate": false, "reason": "payload_too_large",
			"reason_text": _reason_text("payload_too_large"),
			"state": _organization_state()})
		return
	var parsed: Variant = JSON.parse_string(payload)
	var request: Dictionary = parsed if parsed is Dictionary else {}
	var request_id: String = str(request.get("request_id", ""))
	var action: String = str(request.get("action", ""))
	var args_value: Variant = request.get("args", {})
	var refusal_id: String = request_id if request_id.length() <= FarmCommand.MAX_ID_LENGTH else ""
	# 组织操作会持久化，与 submit/social/territory 共用命令令牌桶。
	if not _admit(sender, RATE_KIND_COMMAND, refusal_id, false, false, true).is_empty():
		return
	if request_id.is_empty() or not args_value is Dictionary:
		_send_organization(sender, request_id, {"ok": false, "action": action, "org_id": "",
			"duplicate": false, "reason": "invalid_request",
			"reason_text": _reason_text("invalid_request"), "state": _organization_state()})
		return
	var args: Dictionary = args_value as Dictionary
	var reply: Dictionary = organization_for_member(sender, action, args)
	var document: Dictionary = {
		"ok": bool(reply.get("ok", false)),
		"action": action,
		"org_id": str(reply.get("org_id", "")),
		"duplicate": bool(reply.get("duplicate", false)),
		"reason": str(reply.get("reason", "")),
		"reason_text": str(reply.get("reason_text", "")),
		"state": _organization_state(),
	}
	_send_organization(sender, request_id, document)


@rpc("authority", "call_remote", "reliable", 12)
func _organization_reply(request_id: String, payload: String) -> void:
	pass


func _refusal(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "reason_text": _reason_text(reason), "stage": "",
		"duplicate": false, "reward_crop_id": "", "reward_amount": 0,
		"sequence": world.farm.event_sequence() if world.farm != null else 0}


static func _territory_refusal(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "reason_text": _territory_reason_text(reason)}


## 地籍答复随附的权威视图。世界尚未打开时返回空文档，而不是隐藏失败。
func _territory_state() -> Dictionary:
	return world.territory_view() if world != null else {}


## 组织答复随附的权威视图。世界尚未打开时返回空组织表。
func _organization_state() -> Dictionary:
	return world.organizations_view() if world != null else {"organizations": []}


static func _organization_refusal(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason,
		"reason_text": _organization_reason_text(reason)}


## Land refusals reuse the generic lines where they say the right thing, and keep
## their own wording where the economy line would describe orders instead of
## parcels.
static func _territory_reason_text(reason: String) -> String:
	match reason:
		"not_open": return "世界尚未打开。"
		"not_owner": return "这块地不属于你。"
		"not_owned": return "这块地还没有归属。"
		"unknown_parcel": return "找不到这块地。"
		"already_claimed": return "这块地已经被主张。"
		"already_public": return "这是公共地块。"
		"same_owner": return "不能转让给当前权利人。"
		"time_regression": return "土地操作时间早于上次操作。"
		"overlapping_parcels": return "地块边界重叠。"
		"wrong_world": return "地块不属于这个世界。"
		"invalid_state": return "地籍状态无效。"
		"unknown_action": return "未知的土地操作。"
	return _reason_text(reason)


## Organization refusals are about membership and positions, so their wording
## names who may do what instead of reusing the land or economy lines.
static func _organization_reason_text(reason: String) -> String:
	match reason:
		"not_open": return "世界尚未打开。"
		"already_exists": return "这个组织已经存在。"
		"unknown_org": return "找不到这个组织。"
		"already_member": return "已经是这个组织的成员。"
		"not_member": return "不是这个组织的成员。"
		"last_member": return "最后一名成员不能离开组织。"
		"leader_must_transfer": return "负责人必须先交接给其他成员。"
		"target_not_member": return "目标玩家不是组织成员。"
		"role_forbidden": return "当前职位不能执行这个操作。"
		"leader_requires_transfer": return "负责人只能通过交接产生。"
		"not_leader": return "只有负责人可以交接。"
		"same_leader": return "不能把负责人交接给自己。"
		"invalid_org": return "组织编号无效。"
		"invalid_name": return "组织名称无效。"
		"invalid_role": return "职位无效。"
		"invalid_state": return "组织状态无效。"
		"unknown_action": return "未知的组织操作。"
		"duplicate": return "这条组织操作已经执行过。"
	return _reason_text(reason)


## Every authority→member document passes through this one budget check. The
## transport silently drops an oversized packet and still reports OK, so the
## decision has to happen here, before rpc_id.
func _encode_document(document: Dictionary) -> Dictionary:
	return WorldPayload.encode(JSON.stringify(document))


func _send_payload(peer_id: int, request_id: String, document: Dictionary) -> Dictionary:
	return _send_encoded(peer_id, request_id, _encode_document(document))


## A summary repeats the field grid in `snapshot.farm.fields`. If the full
## document cannot fit even compressed, drop that display-only copy once and
## retry; a member restores the farm from the snapshot, not from this view.
func _send_summary(peer_id: int, document: Dictionary) -> Dictionary:
	var encoded: Dictionary = _encode_document(document)
	if not bool(encoded.get("ok", false)):
		var reduced: Dictionary = document.duplicate(true)
		reduced.erase("fields")
		encoded = _encode_document(reduced)
	return _send_encoded(peer_id, "summary", encoded)


## Sends an encoded document, or a small visible refusal when even compression
## could not bring it under the budget. The refusal itself is far below the
## limit, so the peer learns "payload_too_large" instead of receiving nothing.
func _send_encoded(peer_id: int, request_id: String, encoded: Dictionary) -> Dictionary:
	if bool(encoded.get("ok", false)):
		command_result.rpc_id(peer_id, request_id, str(encoded.get("payload", "")))
		return encoded
	return _reject(peer_id, request_id, encoded, true)


## Social replies travel on their own authority RPC, so they need the same
## budget on that channel: an inbox or contact list can outgrow one packet even
## though a single message never does.
func _send_social(peer_id: int, request_id: String, document: Dictionary) -> void:
	var encoded: Dictionary = _encode_document(document)
	if bool(encoded.get("ok", false)):
		_social_reply.rpc_id(peer_id, request_id, str(encoded.get("payload", "")))
		return
	_reject(peer_id, request_id, encoded, false)


## 地籍答复（含完整权威地籍视图）同样经过线上预算，超出时回一条可见拒绝。
func _send_territory(peer_id: int, request_id: String, document: Dictionary) -> void:
	var encoded: Dictionary = _encode_document(document)
	if bool(encoded.get("ok", false)):
		_territory_reply.rpc_id(peer_id, request_id, str(encoded.get("payload", "")))
		return
	_reject(peer_id, request_id, encoded, false, true)


## 组织答复（含权威组织视图）走自己的权威 RPC，并共用 48 KiB 预算。
func _send_organization(peer_id: int, request_id: String, document: Dictionary) -> void:
	var encoded: Dictionary = _encode_document(document)
	if bool(encoded.get("ok", false)):
		_organization_reply.rpc_id(peer_id, request_id, str(encoded.get("payload", "")))
		return
	_reject(peer_id, request_id, encoded, false, false, true)


## Counts, logs and answers one over-budget document instead of letting the
## transport drop it silently.
func _reject(peer_id: int, request_id: String, encoded: Dictionary,
		on_command_channel: bool, on_territory_channel: bool = false,
		on_organization_channel: bool = false) -> Dictionary:
	payload_rejections += 1
	push_warning("world payload rejected request=%s raw=%d wire=%d reason=%s" % [
		request_id, int(encoded.get("raw_bytes", 0)), int(encoded.get("wire_bytes", 0)),
		str(encoded.get("reason", ""))])
	var refusal: String = JSON.stringify({
		"ok": false, "error": "payload_too_large", "reason": "payload_too_large",
		"reason_text": _reason_text("payload_too_large"),
		"raw_bytes": int(encoded.get("raw_bytes", 0)),
		"wire_bytes": int(encoded.get("wire_bytes", 0)),
	})
	if on_territory_channel:
		_territory_reply.rpc_id(peer_id, request_id, refusal)
	elif on_organization_channel:
		_organization_reply.rpc_id(peer_id, request_id, refusal)
	elif on_command_channel:
		command_result.rpc_id(peer_id, request_id, refusal)
	else:
		_social_reply.rpc_id(peer_id, request_id, refusal)
	return encoded


## Returns {} when the request may proceed. Otherwise it counts the refusal,
## logs it and sends the peer a small rate_limited document through the same
## budget-checked channel as its normal reply, so the request is never silently
## dropped. Each kind has its own bucket: a member that refreshes summaries too
## often can still submit commands, and vice versa.
func _admit(peer_id: int, kind: String, request_id: String, social: bool,
		territory: bool = false, organization: bool = false) -> Dictionary:
	if _rate_allow(peer_id, kind):
		return {}
	rate_rejections += 1
	var document: Dictionary = _rate_limited_document()
	push_warning("world rate limited peer=%d request=%s kind=%s" % [
		peer_id, request_id, kind])
	if territory:
		_send_territory(peer_id, request_id, document)
	elif organization:
		_send_organization(peer_id, request_id, document)
	elif social:
		_send_social(peer_id, request_id, document)
	else:
		_send_payload(peer_id, request_id, document)
	return document


static func _rate_limited_document() -> Dictionary:
	return {
		"ok": false, "error": "rate_limited", "reason": "rate_limited",
		"reason_text": _reason_text("rate_limited"),
	}


## A token bucket per peer and kind. Refills are capped at the burst size, so an
## idle connection never banks more than one burst. The bucket is never removed
## here: a rejection keeps its partially refilled state, and only disconnect or
## a new authority resets it.
func _rate_allow(peer_id: int, kind: String) -> bool:
	var now_ms: int = Time.get_ticks_msec()
	var burst: float = float(_rate_burst(kind))
	var buckets: Dictionary = _rate.get(peer_id, {}) as Dictionary
	var bucket: Dictionary = buckets.get(kind, {}) as Dictionary
	if bucket.is_empty():
		bucket = {"tokens": burst, "at_ms": now_ms}
	else:
		var elapsed: float = maxf(float(now_ms - int(bucket.at_ms)) / 1000.0, 0.0)
		bucket.tokens = minf(burst, float(bucket.tokens) + elapsed * _rate_refill(kind))
		bucket.at_ms = now_ms
	if float(bucket.tokens) < 1.0:
		buckets[kind] = bucket
		_rate[peer_id] = buckets
		return false
	bucket.tokens = float(bucket.tokens) - 1.0
	buckets[kind] = bucket
	_rate[peer_id] = buckets
	return true


static func _rate_burst(kind: String) -> int:
	match kind:
		RATE_KIND_SUMMARY: return RATE_SUMMARY_BURST
		RATE_KIND_CATCH_UP: return RATE_CATCH_UP_BURST
	return RATE_COMMAND_BURST


static func _rate_refill(kind: String) -> float:
	match kind:
		RATE_KIND_SUMMARY: return RATE_SUMMARY_REFILL_PER_SECOND
		RATE_KIND_CATCH_UP: return RATE_CATCH_UP_REFILL_PER_SECOND
	return RATE_COMMAND_REFILL_PER_SECOND


## Builds the document one peer receives. ADR-027: the authority may keep the
## whole world, but every outgoing summary is a per-recipient projection. The
## viewer identity comes from the connection, never from a client claim.
func _summary_document(peer_id: int) -> Dictionary:
	var viewer: String = _player_id(peer_id)
	var role: String = str(_members.get(peer_id, ""))
	var document: Dictionary = WorldProjection.project_summary(world, viewer, role,
		_sequence())
	document["world_id"] = world_id
	document["run_generation"] = run_generation
	return document


## Broadcasts the summary a member would get from request_summary(). The
## per-peer role and private blocks differ, so each payload is built separately.
## Economy commands carry no identity on the wire, so other members need this
## document rather than the raw command to learn the new balances and public
## order/contract aggregates.
func _broadcast_summary() -> void:
	if world == null or world.farm == null:
		return
	for peer_id: int in _members.keys():
		_send_summary(peer_id, _summary_document(peer_id))


## Chinese text for a refusal the sender can display directly. Unknown reasons
## keep the machine string as their fallback so a new refusal is still visible
## instead of silently disappearing.
static func _reason_text(reason: String) -> String:
	match reason:
		"invalid_command": return "操作编号或参数无效。"
		"invalid_request": return "请求无效。"
		"invalid_grant": return "授权参数无效。"
		"payload_too_large": return "指令过大。"
		"rate_limited": return "请求太频繁，请稍后再试。"
		"invalid_time": return "时间无效，请稍后再试。"
		"invalid_owner", "invalid_player", "no_player": return "玩家身份无效。"
		"not_a_member": return "尚未加入这个世界。"
		"forbidden": return "当前身份不能执行这个操作。"
		"read_only": return "世界正在迁移，暂时只读。"
		"stale_precondition": return "世界已经变化，请刷新后再试。"
		"missing_precondition": return "缺少状态基准，请刷新后再试。"
		"invalid_side": return "买卖方向无效。"
		"invalid_good": return "这种商品不能上市。"
		"invalid_price": return "价格无效。"
		"invalid_quantity": return "数量无效。"
		"invalid_expiry": return "有效期必须晚于现在。"
		"invalid_market": return "市场状态无效。"
		"invalid_route": return "这两处市场之间不能发货。"
		"order_exists": return "这张订单已经提交过。"
		"order_limit": return "订单太多了，先撤掉一些。"
		"merchant_closed": return "商人还没有开市。"
		"already_opened", "already_granted": return "已经开通过。"
		"grant_already_issued": return "这个身份已经领过开户赠款；请继续使用原来的玩家身份。"
		"insufficient_cash", "insufficient": return "现金不够。"
		"insufficient_goods": return "货物不够。"
		"unknown_account": return "还没有开户。"
		"order_closed": return "这张订单已经关闭。"
		"order_expired": return "这张订单已经到期。"
		"not_owner": return "只能操作自己的订单。"
		"unknown_order": return "找不到这张订单。"
		"shipment_exists": return "这次发货已经提交过。"
		"shipment_limit": return "在途发货太多了。"
		"delivery_limit": return "交付记录已满。"
		"invalid_principal": return "借款金额无效。"
		"invalid_term": return "还款期限无效。"
		"invalid_borrower": return "借款人身份无效。"
		"bank_closed": return "银行还没有开业。"
		"bank_insufficient": return "银行资金不足。"
		"loan_active": return "你已有一笔未还清的贷款。"
		"loan_limit": return "贷款笔数已达上限。"
		"loan_not_found": return "找不到这笔贷款。"
		"not_borrower": return "只能偿还自己的贷款。"
		"already_repaid": return "这笔贷款已经还清。"
		"command_conflict": return "操作编号重复。"
		"time_backwards": return "命令时间早于世界时间。"
		"time_forwards": return "命令时间超出服务器允许范围。"
		"duplicate": return "这条命令已经执行过。"
		"invalid_amount": return "金额无效。"
		"invalid_sequence": return "支付序号无效。"
		"stale_sequence": return "支付序号已过期，请用新的序号重新提交。"
		"invalid_bank": return "银行状态无效。"
		"invalid_ledger": return "账本状态无效。"
		"not_parcel_owner": return "这块地不属于你，不能在这里建造。"
		"slot_unmapped": return "这个宅基还没有对应地块，暂时不能建造。"
		"land_unavailable": return "地籍尚未载入，暂时不能建造。"
		"stale_land": return "土地状态已变化，请重试。"
		"empty": return "这里还没有建筑。"
	if reason.begins_with("save_land_"): return "土地状态未能保存这次操作。"
	return "操作没有完成：" + reason


@rpc("any_peer", "call_remote", "reliable", 4)
func request_summary() -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if not _members.has(sender):
		return
	# Serializing the whole world happens below; throttle before building it.
	if not _admit(sender, RATE_KIND_SUMMARY, "summary", false).is_empty():
		return
	# ADR-027: this is the same per-recipient projection the broadcast uses. The
	# snapshot inside is what a member restores when the tail aged out, and its
	# `view` marker selects the non-authoritative restore path.
	_send_summary(sender, _summary_document(sender))


func identity() -> Dictionary:
	return {"world_id": world_id, "run_generation": run_generation}
