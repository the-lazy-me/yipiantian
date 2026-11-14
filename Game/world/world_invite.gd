extends RefCounted
## Invitation grants: the shareable form of world membership.
##
## A code is a self-describing string an operator can hand to someone. It names
## the world it is valid for, the role it confers, when it stops being valid and
## whether it may be spent more than once; the secret inside is what the client
## proves with HMAC. The code itself is the credential: anyone holding it can
## use it until it expires, is revoked, or its uses run out.
##
## Nothing here touches the network or the disk. The host owns redemption state;
## this module owns what a grant means.

const VERSION: int = 1
const PREFIX: String = "FARM1."
const MAX_CODE_BYTES: int = 1024
const MAX_ID_LENGTH: int = 64
const MIN_SECRET_BYTES: int = 32
const MAX_SECRET_BYTES: int = 64

const MEMBER: String = "member"
const VISITOR: String = "visitor"
const ROLES: Array[String] = [MEMBER, VISITOR]

## What each role may submit. A visitor can tend a world it was invited to see
## but cannot take its produce; that is the only distinction worth drawing until
## there is a real management action to gate.
const PERMISSIONS: Dictionary = {
	MEMBER: ["harvest", "sow", "water", "weed", "till"],
	VISITOR: ["water", "weed"],
}
const KEYS: Array[String] = [
	"version", "id", "secret", "role", "world_id", "expires_at", "one_time",
]


static func allows(role: String, kind: String) -> bool:
	var kinds: Array = PERMISSIONS.get(role, [])
	return kinds.has(kind)


## Builds a grant. `expires_at` 0 means it never expires.
static func make(id: String, secret: PackedByteArray, role: String, world_id: String,
		expires_at: float = 0.0, one_time: bool = true) -> Dictionary:
	var grant: Dictionary = {
		"version": VERSION, "id": id, "secret": secret, "role": role,
		"world_id": world_id, "expires_at": expires_at, "one_time": one_time,
	}
	return grant if _valid(grant).ok else {}


## A fresh grant with a new id and secret. The id is separate from the secret so
## an operator can revoke a code they shared without ever seeing it again.
static func issue(role: String, world_id: String, expires_at: float = 0.0,
		one_time: bool = true) -> Dictionary:
	var crypto := Crypto.new()
	var bytes: PackedByteArray = crypto.generate_random_bytes(16)
	var parts: PackedStringArray = PackedStringArray()
	for byte: int in bytes:
		parts.append("%02x" % byte)
	return make("".join(parts), crypto.generate_random_bytes(32), role, world_id,
		expires_at, one_time)


## The shareable form: a prefix plus base64 of the JSON grant. The prefix lets a
## UI recognise a pasted code before trying to parse it.
static func encode(grant: Dictionary) -> String:
	if not _valid(grant).ok:
		return ""
	var wire: Dictionary = grant.duplicate(true)
	wire.secret = Marshalls.raw_to_base64(grant.secret)
	return PREFIX + Marshalls.raw_to_base64(JSON.stringify(wire, "", true, false).to_utf8_buffer())


## Parses a pasted code. A hostile source may hand us anything, so the size is
## bounded and every field is checked before the grant is used.
static func decode(code: String) -> Dictionary:
	var body: String = code.strip_edges()
	if body.is_empty() or body.length() > MAX_CODE_BYTES * 2:
		return _failure("invalid_code")
	if not body.begins_with(PREFIX):
		return _failure("invalid_code")
	# Tolerate a code that was wrapped across lines when it was copied.
	body = body.substr(PREFIX.length()).replace("\n", "").replace(" ", "")
	var raw: PackedByteArray = Marshalls.base64_to_raw(body)
	if raw.is_empty() or raw.size() > MAX_CODE_BYTES:
		return _failure("invalid_code")
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if not parsed is Dictionary:
		return _failure("invalid_code")
	var wire: Dictionary = parsed
	var grant: Dictionary = wire.duplicate(true)
	var secret: Variant = wire.get("secret")
	if not secret is String:
		return _failure("invalid_code")
	grant.secret = Marshalls.base64_to_raw(str(secret))
	var shape: Dictionary = _valid(grant)
	if not shape.ok:
		return shape
	return {"ok": true, "reason": "", "grant": grant}


## Whether a grant may be redeemed now. `uses` is how many times it already was.
static func check_usable(grant: Dictionary, now: float, uses: int) -> Dictionary:
	var shape: Dictionary = _valid(grant)
	if not shape.ok:
		return shape
	if grant.one_time and uses >= 1:
		return _failure("invite_used")
	# An expiry in the past is the normal end of a shared code; report it as the
	# reason so the client can say "ask for a new code" instead of "no access".
	if float(grant.expires_at) > 0.0 and now >= float(grant.expires_at):
		return _failure("invite_expired")
	return {"ok": true, "reason": ""}


static func _valid(grant: Dictionary) -> Dictionary:
	if grant.size() != KEYS.size():
		return _failure("invalid_grant")
	for key: String in KEYS:
		if not grant.has(key):
			return _failure("invalid_grant")
	if not (grant.version is int or grant.version is float) or int(grant.version) != VERSION:
		return _failure("protocol_version")
	if not grant.id is String or str(grant.id).is_empty() or str(grant.id).length() > MAX_ID_LENGTH:
		return _failure("invalid_grant_id")
	if not grant.role is String or not ROLES.has(str(grant.role)):
		return _failure("invalid_role")
	if not grant.world_id is String or str(grant.world_id).is_empty() \
			or str(grant.world_id).length() > MAX_ID_LENGTH:
		return _failure("invalid_world_id")
	if not grant.secret is PackedByteArray or grant.secret.size() < MIN_SECRET_BYTES \
			or grant.secret.size() > MAX_SECRET_BYTES:
		return _failure("invalid_secret")
	if not (grant.expires_at is int or grant.expires_at is float) \
			or not is_finite(float(grant.expires_at)) or float(grant.expires_at) < 0.0:
		return _failure("invalid_expiry")
	if not grant.one_time is bool:
		return _failure("invalid_grant")
	return {"ok": true, "reason": ""}


static func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
