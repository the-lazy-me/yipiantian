extends Node
## Desktop client lifecycle for a shared world.
##
## The scene must not touch transport, TLS, authentication or join ordering, so
## those live here: one place creates the peer from a join code, answers the
## invite challenge, waits for the authoritative summary and then hands the scene
## a farm it can render. The scene never writes a farm snapshot in this mode;
## every change comes back from the authority.
##
## Join codes already carry the endpoint and the pinned certificate, so no user
## step imports a certificate by hand.

const WorldMember = preload("res://world/world_member.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const WorldPayload = preload("res://world/world_payload.gd")

const SESSION_NODE_NAME: String = "WorldSession"


## The session node this client creates decodes the wire format before the base
## member parses JSON. A compressed document that is damaged, truncated or lies
## about its length names a failure and leaves the state untouched; it never
## reaches the base as an empty dictionary.
class WireMember extends "res://world/world_member.gd":
	const Payload = preload("res://world/world_payload.gd")

	@rpc("authority", "call_remote", "reliable", 2)
	func command_result(request_id: String, payload: String) -> void:
		var decoded: Dictionary = Payload.decode(payload)
		if not bool(decoded.get("ok", false)):
			authority_lost.emit(str(decoded.get("reason", "payload_decode_failed")))
			return
		var text: String = str(decoded.get("text", ""))
		var parsed: Variant = JSON.parse_string(text)
		# Every authority document is a JSON object. Anything else would reach the
		# base as `{}` and erase a confirmed snapshot, so it never gets there.
		if not parsed is Dictionary:
			authority_lost.emit("payload_decode_failed")
			return
		# The host's visible refusal is not a snapshot. Keep the last confirmed
		# one so weather, social and restore derivations do not fall back to empty
		# while the next reconcile asks again.
		var refused: bool = request_id == "summary" \
			and Payload.is_summary_refusal(parsed as Dictionary)
		var previous_snapshot: Dictionary = snapshot
		var previous_state: Dictionary = state
		super.command_result(request_id, text)
		if refused:
			snapshot = previous_snapshot
			state = previous_state

	## Social documents are the largest variable reply (an inbox of bounded but
	## many messages), so they use the same wire budget as every other document.
	@rpc("authority", "call_remote", "reliable", 8)
	func _social_reply(request_id: String, payload: String) -> void:
		var decoded: Dictionary = Payload.decode(payload)
		if not bool(decoded.get("ok", false)):
			authority_lost.emit(str(decoded.get("reason", "payload_decode_failed")))
			return
		super._social_reply(request_id, str(decoded.get("text", "")))

	## 地籍答复与其它权威文档走同一个线上预算，必须先解码再交给基类解析。
	@rpc("authority", "call_remote", "reliable", 10)
	func _territory_reply(request_id: String, payload: String) -> void:
		var decoded: Dictionary = Payload.decode(payload)
		if not bool(decoded.get("ok", false)):
			authority_lost.emit(str(decoded.get("reason", "payload_decode_failed")))
			return
		super._territory_reply(request_id, str(decoded.get("text", "")))
## How often a connected client reconciles with a fresh summary. Commands are
## applied locally the moment they are acknowledged; this only corrects drift.
const RECONCILE_SECONDS: float = 30.0
## 断线重连的退避表：1s、2s、4s、8s、16s，之后固定每 30s 一次。总时长不设
## 硬上限，网络分区恢复后客户端会自己回来。
const RECONNECT_DELAYS: Array[float] = [1.0, 2.0, 4.0, 8.0, 16.0, 30.0]
## 一次拨号到拿到加入回复的最长等待。WebSocket 对端不存在时不一定触发
## connection_failed，这个看门狗保证退避继续向前走，而不是停在一次拨号上。
const DIAL_TIMEOUT_SECONDS: float = 10.0
## 这些加入拒绝重试同一张码不会有不同结果，只有它们会彻底放弃。
const TERMINAL_JOIN_REFUSALS: Array[String] = [
	"invite_expired", "invite_revoked", "invite_used", "world_mismatch",
	"protocol_version", "rules_version", "invalid_player", "not_authenticated",
	"already_joined",
]

signal state_ready(farm: RefCounted, decorations: RefCounted, now_utc: float)
signal refused(reason: String)
signal lost(reason: String)
## 一次重连尝试前的退避通知；delay 是这次等待的秒数。
signal reconnecting(attempt: int, delay: float)
## 重连成功且权威快照已整份校正本地；sequence 是校正后的权威序号。
signal reconnected(sequence: int)
signal committed(request_id: String, reply: Dictionary)
signal changed(entry: Dictionary)
## 权威对一次地籍请求的答复；转发自成员节点的同名信号。
signal territory_result(request_id: String, payload: Dictionary)
## 已经加入的世界拒绝了一份整份摘要：连接还在，画面停在最后一次确认的状态。
signal summary_refused(reason: String)

var member: WorldMember
var url: String = ""
var server_name: String = ""
var certificate_pem: String = ""
var grant: Dictionary = {}
var player_id: String = ""
var display_name: String = ""
## The local profile's player credential; a rebuilt session node must present
## the same one or the authority refuses the id it was bound to.
var player_secret: PackedByteArray
var joined: bool = false
## True once a summary was actually applied. `joined` only means the authority
## accepted the seat, which happens before the first summary arrives.
var _has_snapshot: bool = false

var _peer: WebSocketMultiplayerPeer
var _auth_sent: bool = false
var _clock_base: float = 0.0
var _clock_ms: int = 0
var _last_summary_ms: int = 0
var _closed: bool = false
## 重连状态机：_reconnecting 表示已经进入自动重试；_waiting_for_retry 表示
## 一个退避计时器已经排好，期间重复的断线通知不再叠加计时器。
var _reconnecting: bool = false
var _waiting_for_retry: bool = false
var _reconnect_attempt: int = 0
## 每次排计时器都递增；节点释放或 close() 也递增，让旧的计时器安全作废。
var _reconnect_token: int = 0
var _dial_deadline_ms: int = 0
## 只有真正进过一次世界才自动重连。第一次加入就被拒（码过期、秘密不对、
## 版本不符）重试同一张码不会有不同答案，应该把原因交给调用方去显示。
var _ever_joined: bool = false


## Starts from a pasted join code. Returns false and emits `refused` when the
## code is unusable, so the caller can show that reason before a scene exists.
func start(code: String, player: String, name: String,
		profile_secret: PackedByteArray = PackedByteArray()) -> bool:
	var parsed: Dictionary = WorldJoinCode.decode(code)
	if not parsed.ok:
		refused.emit(str(parsed.reason))
		return false
	url = str(parsed.url)
	server_name = str(parsed.server_name)
	certificate_pem = str(parsed.certificate)
	grant = parsed.grant
	player_id = player.strip_edges()
	display_name = name.strip_edges()
	player_secret = profile_secret
	var certificate := X509Certificate.new()
	if certificate.load_from_string(certificate_pem) != OK:
		refused.emit("invalid_certificate")
		return false
	_peer = WebSocketMultiplayerPeer.new()
	if _peer.create_client(url, TLSOptions.client(certificate, server_name)) != OK:
		refused.emit("connect_failed")
		return false
	member = WireMember.new()
	member.name = SESSION_NODE_NAME
	member.grant_id = str(grant.id)
	member.player_id = player_id
	member.display_name = display_name
	member.player_secret = player_secret
	# RPCs route by node path, so the member has to sit exactly where the host's
	# session node sits: directly under the tree root, whatever scene is loaded.
	get_tree().root.add_child(member)
	_wire_member()
	multiplayer.multiplayer_peer = _peer
	multiplayer.auth_callback = _answer_challenge
	member.connect_to(url, grant.secret, str(grant.world_id))
	return true


## 成员节点的信号只连一次。重连复用同一个成员节点时不会重复注册回调。
func _wire_member() -> void:
	member.joined.connect(_on_joined)
	member.join_failed.connect(_on_join_failed)
	member.authority_lost.connect(_on_authority_lost)
	member.reply_received.connect(_on_reply)
	member.remote_change.connect(func(entry: Dictionary) -> void: changed.emit(entry))
	member.territory_result.connect(func(request_id: String, payload: Dictionary) -> void:
		territory_result.emit(request_id, payload))


func _process(_delta: float) -> void:
	if _closed:
		return
	if _peer == null or member == null:
		return
	# The transport reports CONNECTED before the session is authenticated; the
	# invite answer has to go out here, not on the authenticated signal. 重连时
	# 同样要走这一步：新 peer 连上后仍要先回答质询。
	if not _auth_sent and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_auth_sent = true
		multiplayer.send_auth(1, member.auth_hello())
	if _reconnecting:
		# 拨号迟迟没有结果（例如对端不存在但没报错）时继续按退避重试。
		if _dial_deadline_ms > 0 and Time.get_ticks_msec() > _dial_deadline_ms:
			_lose_authority("connect_timeout")
		return
	if not joined:
		return
	var now_ms: int = Time.get_ticks_msec()
	if _last_summary_ms > 0 and now_ms - _last_summary_ms >= int(RECONCILE_SECONDS * 1000.0):
		_last_summary_ms = now_ms
		member.request_summary.rpc_id(1)


## Answers the server's challenge with HMAC over the invite secret. The secret
## itself never crosses the wire.
func _answer_challenge(_id: int, data: PackedByteArray) -> void:
	var digest := Crypto.new().hmac_digest(HashingContext.HASH_SHA256, grant.secret, data)
	multiplayer.send_auth(1, digest)
	multiplayer.complete_auth(1)


func _on_joined(_state: Dictionary) -> void:
	joined = true
	_ever_joined = true
	_last_summary_ms = Time.get_ticks_msec()
	_dial_deadline_ms = 0
	if _reconnecting:
		# 加入已成功；给权威快照一个期限，摘要迟迟不来时继续退避重试。
		_dial_deadline_ms = Time.get_ticks_msec() + int(DIAL_TIMEOUT_SECONDS * 1000.0)
		# 重连时 join 回复本身已请求一次 summary；这里再立即要一份，确保画面
		# 在最短时间内由权威快照整份校正（重复的一份按同一摘要幂等应用）。
		member.request_summary.rpc_id(1)


func _on_join_failed(reason: String) -> void:
	joined = false
	if not _ever_joined:
		_stop_retrying()
		refused.emit(reason)
		return
	if reason in TERMINAL_JOIN_REFUSALS:
		_abandon(reason)
		return
	_lose_authority("join_" + reason)


func _on_authority_lost(reason: String) -> void:
	if _closed:
		return
	joined = false
	if not _ever_joined:
		_stop_retrying()
		refused.emit(reason)
		return
	_lose_authority(reason)


## Enters (or continues) the retry loop. Repeated loss notifications during the
## same attempt do not stack timers.
func _lose_authority(_reason: String) -> void:
	if _closed or _waiting_for_retry:
		return
	joined = false
	# 一次尝试可能先收到 server_disconnected 再收到 connection_failed；只保留第一次。
	if not _reconnecting:
		_reconnecting = true
		_reconnect_attempt = 0
	_queue_reconnect()


func _queue_reconnect() -> void:
	if _closed:
		return
	_waiting_for_retry = true
	_dial_deadline_ms = 0
	_reconnect_attempt += 1
	var delay: float = RECONNECT_DELAYS[mini(_reconnect_attempt - 1, RECONNECT_DELAYS.size() - 1)]
	reconnecting.emit(_reconnect_attempt, delay)
	_arm_reconnect(delay)


## Waits on a SceneTree timer rather than a node timer, so releasing this node
## while a retry is pending lets the await return safely; the token then rejects
## the stale continuation.
func _arm_reconnect(delay: float) -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	_reconnect_token += 1
	var token: int = _reconnect_token
	await tree.create_timer(delay).timeout
	if token != _reconnect_token or _closed or not is_inside_tree():
		return
	_waiting_for_retry = false
	_attempt_reconnect()


func _attempt_reconnect() -> void:
	if _closed or not is_inside_tree():
		return
	_drop_peer()
	if not _ensure_member():
		_queue_reconnect()
		return
	var certificate := X509Certificate.new()
	if certificate.load_from_string(certificate_pem) != OK:
		_abandon("invalid_certificate")
		return
	_peer = WebSocketMultiplayerPeer.new()
	_auth_sent = false
	if _peer.create_client(url, TLSOptions.client(certificate, server_name)) != OK:
		_drop_peer()
		_queue_reconnect()
		return
	multiplayer.multiplayer_peer = _peer
	multiplayer.auth_callback = _answer_challenge
	# 复用同一个成员节点时不会重复连接 SceneMultiplayer 信号；成员节点已经
	# 失效（例如被外部释放）时重建，路径仍必须是 /root/WorldSession。
	member.connect_to(url, grant.secret, str(grant.world_id))
	_dial_deadline_ms = Time.get_ticks_msec() + int(DIAL_TIMEOUT_SECONDS * 1000.0)


## 旧 peer 必须先摘掉再关闭：关闭可能同步发出断线信号，而新连接马上要写回
## multiplayer.multiplayer_peer。
func _drop_peer() -> void:
	if _peer != null:
		_peer.close()
		if multiplayer.multiplayer_peer == _peer:
			multiplayer.multiplayer_peer = null
		_peer = null


func _ensure_member() -> bool:
	if member != null and is_instance_valid(member):
		return true
	var existing: Node = get_tree().root.get_node_or_null(SESSION_NODE_NAME)
	if existing != null:
		# 同名节点会让 RPC 路径变成 WorldSession2；先移除残留节点。
		get_tree().root.remove_child(existing)
		existing.queue_free()
	member = WireMember.new()
	member.name = SESSION_NODE_NAME
	member.grant_id = str(grant.id)
	member.player_id = player_id
	member.display_name = display_name
	member.player_secret = player_secret
	get_tree().root.add_child(member)
	_wire_member()
	return true


## Gives up for good: no retry can change the answer.
func _abandon(reason: String) -> void:
	_stop_retrying()
	if _closed:
		return
	lost.emit(reason)


## Stops every pending retry. Also used when a first join is refused: the caller
## gets the reason instead of an endless queue of identical attempts.
func _stop_retrying() -> void:
	_reconnecting = false
	_waiting_for_retry = false
	_dial_deadline_ms = 0
	_reconnect_attempt = 0
	_reconnect_token += 1


func _on_reply(request_id: String, payload: Dictionary) -> void:
	if request_id == "summary":
		# A refused summary is not a lost connection: the authority keeps the
		# seat and the last confirmed state stays. Before the first applied
		# summary there is no such state, so the join itself has failed.
		if WorldPayload.is_summary_refusal(payload):
			var refusal: String = str(payload.get("reason", payload.get("error", "")))
			if _has_snapshot:
				summary_refused.emit(refusal)
			else:
				lost.emit(refusal)
			return
		var restored: Dictionary = member.restore_state()
		if not restored.ok:
			# 坏快照不能当权威用；重连期间下一轮退避会重新取一份。
			joined = false
			if _reconnecting:
				_lose_authority(str(restored.reason))
			else:
				lost.emit(str(restored.reason))
			return
		_clock_base = float(restored.now_utc)
		_clock_ms = Time.get_ticks_msec()
		_has_snapshot = true
		state_ready.emit(restored.farm, restored.decorations, _clock_base)
		if _reconnecting:
			_reconnecting = false
			_waiting_for_retry = false
			_dial_deadline_ms = 0
			_reconnect_attempt = 0
			reconnected.emit(member.last_sequence)
		return
	committed.emit(request_id, payload)


## The authority's world clock, advanced locally between summaries. The host
## advances monotonically from its start instant, so a wall-clock step must not
## move growth; this keeps the same property on the client.
func world_time() -> float:
	if _clock_base <= 0.0:
		return Time.get_unix_time_from_system()
	return _clock_base + float(Time.get_ticks_msec() - _clock_ms) / 1000.0


func submit(command: Dictionary) -> bool:
	if not joined or member == null:
		return false
	var sent: Dictionary = member.submit_command(command)
	return bool(sent.get("ok", false))


func request_summary() -> void:
	if joined and member != null:
		_last_summary_ms = Time.get_ticks_msec()
		member.request_summary.rpc_id(1)


## 转发一次地籍请求。世界未加入或成员节点缺失时返回 false，不假装已发出。
func request_territory(request_id: String, action: String, args: Dictionary = {}) -> bool:
	if not joined or member == null:
		return false
	return member.request_territory(request_id, action, args)


func close() -> void:
	_closed = true
	joined = false
	_has_snapshot = false
	_reconnecting = false
	_waiting_for_retry = false
	_dial_deadline_ms = 0
	_reconnect_attempt = 0
	# 递增 token 让已经排好的 SceneTree 计时器回调安全作废，不再拨号。
	_reconnect_token += 1
	_drop_peer()
	if is_instance_valid(member):
		member.queue_free()
		member = null


func _notification(what: int) -> void:
	# The session node lives directly under the tree root (RPC routes by path), so
	# it is not a child that dies with this node; it must be released explicitly
	# when the client itself is destroyed. Leaving the tree is not that moment:
	# the farm scene reparents this node after startup hands it over.
	if what == NOTIFICATION_PREDELETE:
		_closed = true
		_waiting_for_retry = false
		_dial_deadline_ms = 0
		_reconnect_token += 1
		if is_instance_valid(member):
			member.queue_free()
