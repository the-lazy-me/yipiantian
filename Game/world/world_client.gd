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

const SESSION_NODE_NAME: String = "WorldSession"
## How often a connected client reconciles with a fresh summary. Commands are
## applied locally the moment they are acknowledged; this only corrects drift.
const RECONCILE_SECONDS: float = 30.0

signal state_ready(farm: RefCounted, decorations: RefCounted, now_utc: float)
signal refused(reason: String)
signal lost(reason: String)
signal committed(request_id: String, reply: Dictionary)
signal changed(entry: Dictionary)

var member: WorldMember
var url: String = ""
var server_name: String = ""
var certificate_pem: String = ""
var grant: Dictionary = {}
var player_id: String = ""
var display_name: String = ""
var joined: bool = false

var _peer: WebSocketMultiplayerPeer
var _auth_sent: bool = false
var _clock_base: float = 0.0
var _clock_ms: int = 0
var _last_summary_ms: int = 0
var _closed: bool = false


## Starts from a pasted join code. Returns false and emits `refused` when the
## code is unusable, so the caller can show that reason before a scene exists.
func start(code: String, player: String, name: String) -> bool:
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
	var certificate := X509Certificate.new()
	if certificate.load_from_string(certificate_pem) != OK:
		refused.emit("invalid_certificate")
		return false
	_peer = WebSocketMultiplayerPeer.new()
	if _peer.create_client(url, TLSOptions.client(certificate, server_name)) != OK:
		refused.emit("connect_failed")
		return false
	member = WorldMember.new()
	member.name = SESSION_NODE_NAME
	member.grant_id = str(grant.id)
	member.player_id = player_id
	member.display_name = display_name
	# RPCs route by node path, so the member has to sit exactly where the host's
	# session node sits: directly under the tree root, whatever scene is loaded.
	get_tree().root.add_child(member)
	member.joined.connect(_on_joined)
	member.join_failed.connect(func(reason: String) -> void:
		refused.emit(reason))
	member.authority_lost.connect(func(reason: String) -> void:
		joined = false
		lost.emit(reason))
	member.reply_received.connect(_on_reply)
	member.remote_change.connect(func(entry: Dictionary) -> void: changed.emit(entry))
	multiplayer.multiplayer_peer = _peer
	multiplayer.auth_callback = _answer_challenge
	member.connect_to(url, grant.secret, str(grant.world_id))
	return true


func _process(_delta: float) -> void:
	if _closed or _peer == null or member == null:
		return
	# The transport reports CONNECTED before the session is authenticated; the
	# invite answer has to go out here, not on the authenticated signal.
	if not _auth_sent and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_auth_sent = true
		multiplayer.send_auth(1, member.auth_hello())
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
	_last_summary_ms = Time.get_ticks_msec()


func _on_reply(request_id: String, payload: Dictionary) -> void:
	if request_id == "summary":
		var restored: Dictionary = member.restore_state()
		if not restored.ok:
			lost.emit(str(restored.reason))
			return
		_clock_base = float(restored.now_utc)
		_clock_ms = Time.get_ticks_msec()
		state_ready.emit(restored.farm, restored.decorations, _clock_base)
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


func close() -> void:
	_closed = true
	joined = false
	if _peer != null:
		_peer.close()
	if multiplayer.multiplayer_peer == _peer:
		multiplayer.multiplayer_peer = null
	if is_instance_valid(member):
		member.queue_free()
		member = null


func _notification(what: int) -> void:
	# The session node lives directly under the tree root (RPC routes by path), so
	# it is not a child that dies with this node; it must be released explicitly
	# when the client itself is destroyed. Leaving the tree is not that moment:
	# the farm scene reparents this node after startup hands it over.
	if what == NOTIFICATION_PREDELETE and is_instance_valid(member):
		member.queue_free()
