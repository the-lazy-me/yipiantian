extends RefCounted
## 世界级玩家身份绑定：第一个声明某个 player_id 的连接把该 id 绑定到一个
## 32 字节随机凭据，之后的连接必须出示同一凭据。凭据只在本机档案 player.key
## 里，权威按 id 保存它，从不回传。
##
## 这是信任首次使用（TOFU）：在真正的房主为某个 id 首次加入之前，任何持有
## 有效邀请的人都能抢先认领它。它挡住的是“拿到任何邀请就能冒充已知玩家”的
## 路，而不是邀请本身可信。
##
## 文档形状：
##   { "players": { "<player_id>": { "secret": "<base64>", "created_utc": 12.5 } } }
## 信封版本由 PlayerBindingStore 负责；这里只校验状态本身。

const SocialState = preload("res://social/social_state.gd")

const VERSION: int = 1
const MAX_PLAYERS: int = 1024
const SECRET_BYTES: int = 32
const SECRET_FIELD: String = "secret"
const CREATED_FIELD: String = "created_utc"
## Domain separation for the per-world proof. A world only ever sees this
## derived value, so one world's host cannot replay it against another world.
const PROOF_DOMAIN: String = "yipiantian.player.v1\n"


static func empty_state() -> Dictionary:
	return {"players": {}}


## Strict document check: every entry must be exactly one id and one secret with
## one creation time. Unknown extra keys are refused so a future field cannot be
## silently dropped by an older authority.
static func valid(state: Variant) -> bool:
	if not state is Dictionary or (state as Dictionary).size() != 1:
		return false
	var players: Variant = (state as Dictionary).get("players")
	if not players is Dictionary or (players as Dictionary).size() > MAX_PLAYERS:
		return false
	for player_id: Variant in players:
		if not SocialState.valid_identifier(player_id):
			return false
		var entry: Variant = players[player_id]
		if not entry is Dictionary or (entry as Dictionary).size() != 2:
			return false
		if not valid_secret((entry as Dictionary).get(SECRET_FIELD)):
			return false
		if not _valid_time((entry as Dictionary).get(CREATED_FIELD)):
			return false
	return true


## A credential is 32 raw bytes carried as base64. The client stores the raw
## bytes in player.key; only this canonical text form is persisted or compared.
static func valid_secret(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > 64 or not _is_base64(text):
		return false
	return Marshalls.base64_to_raw(text).size() == SECRET_BYTES


## The value a member presents when joining `world_id`. The installation
## credential itself never crosses the wire: a world host learns only a value
## that this credential alone can reproduce for that world id. An empty or
## malformed credential, or a missing world id, yields "" so the caller can
## refuse the join instead of binding something unusable.
static func proof(secret_text: String, world_id: String) -> String:
	if not valid_secret(secret_text) or world_id.is_empty():
		return ""
	var derived: PackedByteArray = Crypto.new().hmac_digest(
		HashingContext.HASH_SHA256, Marshalls.base64_to_raw(secret_text),
		(PROOF_DOMAIN + world_id).to_utf8_buffer())
	return Marshalls.raw_to_base64(derived)


## Binds `player_id` to `secret_text` on first use. A second bind is refused:
## the caller must verify instead of overwriting.
static func bind(state: Dictionary, player_id: String, secret_text: String,
		at_utc: float) -> Dictionary:
	if not valid(state):
		return {"ok": false, "reason": "invalid_state"}
	if not SocialState.valid_identifier(player_id):
		return {"ok": false, "reason": "invalid_player"}
	if not valid_secret(secret_text):
		return {"ok": false, "reason": "invalid_secret"}
	if not _valid_time(at_utc):
		return {"ok": false, "reason": "invalid_time"}
	var players: Dictionary = state.players
	if players.has(player_id):
		return {"ok": false, "reason": "already_bound"}
	if players.size() >= MAX_PLAYERS:
		return {"ok": false, "reason": "too_many"}
	var candidate: Dictionary = state.duplicate(true)
	candidate.players[player_id] = {
		SECRET_FIELD: _canonical(secret_text),
		CREATED_FIELD: at_utc,
	}
	return {"ok": true, "reason": "", "state": candidate}


## Constant-time comparison against a bound entry. A missing entry is not a
## match: callers must decide separately whether the id is unbound.
static func matches(entry: Variant, secret_text: String) -> bool:
	if not entry is Dictionary or not valid_secret(secret_text):
		return false
	var stored: Variant = (entry as Dictionary).get(SECRET_FIELD)
	if not valid_secret(stored):
		return false
	return Crypto.new().constant_time_compare(
		Marshalls.base64_to_raw(str(stored)), Marshalls.base64_to_raw(secret_text))


## JSON numbers arrive as floats; normalize after the strict check so the
## in-memory document keeps the same shape it was written with.
static func normalize(state: Dictionary) -> void:
	var players: Variant = state.get("players")
	if not players is Dictionary:
		return
	for player_id: Variant in (players as Dictionary):
		var entry: Variant = players[player_id]
		if entry is Dictionary:
			entry[CREATED_FIELD] = float(entry.get(CREATED_FIELD, 0.0))


static func _canonical(secret_text: String) -> String:
	return Marshalls.raw_to_base64(Marshalls.base64_to_raw(secret_text))


## The engine decoder logs an error for malformed input. A mistyped or damaged
## credential is a normal refusal, not a fault, so the alphabet is checked first.
static func _is_base64(text: String) -> bool:
	if text.length() % 4 != 0:
		return false
	var alphabet: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
	for index: int in text.length():
		if not alphabet.contains(text[index]):
			return false
	return true


static func _valid_time(value: Variant) -> bool:
	if not value is float and not value is int:
		return false
	return is_finite(float(value)) and float(value) >= 0.0
