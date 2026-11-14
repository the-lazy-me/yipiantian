extends RefCounted
## World identity continuity across a server move.
##
## A migration descriptor is the only thing that proves "the server at this new
## address is the same world, one generation later". It is signed by the world
## key the client already pinned at invite time, and it commits to the exact
## state the new authority continues from.
##
## This module is pure: it builds, signs, serialises, parses and verifies. It
## never opens a store and never touches the network.

const PROTOCOL_VERSION: int = 1
const MAX_DESCRIPTOR_BYTES: int = 8192
const MAX_IDS: int = 8
const MAX_ID_LENGTH: int = 255
const CLOCK_SKEW: float = 300.0
const KEYS: Array[String] = [
	"protocol_version", "world_id", "run_generation", "previous_generation",
	"sequence", "content_digest", "endpoints", "issued_at", "expires_at",
]


## Digest of the exact continuation point: identity, generation and state.
## Addresses and timestamps are deliberately excluded so the same state moved
## to a different address keeps the same digest.
static func content_digest(world_id: String, run_generation: int, sequence: int,
		snapshot: Dictionary) -> String:
	return canonical_text({
		"world_id": world_id, "run_generation": run_generation,
		"sequence": sequence, "snapshot": snapshot,
	}).sha256_text()


static func canonical_text(value: Variant) -> String:
	# JSON.stringify sorts keys recursively, so the digest does not depend on
	# the dictionary insertion order of the caller.
	return JSON.stringify(value, "", true, false)


## Builds and signs a descriptor. `endpoints` are the new addresses; they are
## part of the signed payload, so an attacker cannot redirect a client to a
## server of their choosing without breaking the signature.
static func sign(world_id: String, run_generation: int, previous_generation: int,
		sequence: int, snapshot: Dictionary, endpoints: Array,
		issued_at: float, expires_at: float, world_key: CryptoKey) -> Dictionary:
	var descriptor: Dictionary = {
		"protocol_version": PROTOCOL_VERSION,
		"world_id": world_id,
		"run_generation": run_generation,
		"previous_generation": previous_generation,
		"sequence": sequence,
		"content_digest": content_digest(world_id, run_generation, sequence, snapshot),
		"endpoints": endpoints,
		"issued_at": issued_at,
		"expires_at": expires_at,
	}
	if not _valid_fields(descriptor, "").ok:
		return {}
	var signature: PackedByteArray = Crypto.new().sign(
		HashingContext.HASH_SHA256, canonical_text(descriptor).sha256_buffer(), world_key)
	if signature.is_empty():
		return {}
	descriptor["signature"] = Marshalls.raw_to_base64(signature)
	return descriptor


## Verifies a descriptor against the identity a client already trusts.
## `highest_generation` is the newest generation that client has accepted.
static func verify(descriptor: Dictionary, world_key: CryptoKey, expected_world_id: String,
		highest_generation: int, now: float) -> Dictionary:
	if descriptor.size() != KEYS.size() + 1:
		return _failure("invalid_descriptor")
	for key: String in KEYS:
		if not descriptor.has(key):
			return _failure("invalid_descriptor")
	var shape: Dictionary = _valid_fields(descriptor, expected_world_id)
	if not shape.ok:
		return shape
	var issued: float = float(descriptor.issued_at)
	var expires: float = float(descriptor.expires_at)
	if now + CLOCK_SKEW < issued:
		return _failure("not_yet_valid")
	if now - CLOCK_SKEW > expires:
		return _failure("expired")
	# A generation must advance by exactly one from the one being replaced, and
	# must not be older than anything this client already accepted. Without the
	# second check a valid old descriptor could be replayed to roll a client
	# back to a stale authority.
	var generation: int = int(descriptor.run_generation)
	var previous: int = int(descriptor.previous_generation)
	if generation <= highest_generation:
		return _failure("stale_generation")
	if previous > highest_generation:
		return _failure("generation_gap")
	var signature: PackedByteArray = Marshalls.base64_to_raw(str(descriptor.signature))
	if signature.is_empty():
		return _failure("invalid_signature")
	var unsigned: Dictionary = descriptor.duplicate(true)
	unsigned.erase("signature")
	var verified: bool = Crypto.new().verify(HashingContext.HASH_SHA256,
		canonical_text(unsigned).sha256_buffer(), signature, world_key)
	if not verified:
		return _failure("bad_signature")
	return {"ok": true, "reason": "", "descriptor": descriptor,
		"run_generation": generation, "sequence": int(descriptor.sequence),
		"endpoints": descriptor.endpoints}


## A hostile source may hand us arbitrary JSON; keep the check bounded.
static func parse(text: String) -> Dictionary:
	if text.is_empty() or text.to_utf8_buffer().size() > MAX_DESCRIPTOR_BYTES:
		return _failure("invalid_descriptor")
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return _failure("invalid_descriptor")
	return {"ok": true, "reason": "", "descriptor": json.data}


static func _valid_fields(descriptor: Dictionary, expected_world_id: String) -> Dictionary:
	if int(descriptor.protocol_version) != PROTOCOL_VERSION:
		return _failure("protocol_version")
	var world_id: Variant = descriptor.world_id
	if not world_id is String or str(world_id).is_empty() or str(world_id).length() > MAX_ID_LENGTH:
		return _failure("invalid_world_id")
	if not expected_world_id.is_empty() and str(world_id) != expected_world_id:
		return _failure("world_mismatch")
	for key: String in ["run_generation", "previous_generation", "sequence"]:
		var value: Variant = descriptor.get(key)
		if not (value is int or value is float) or not is_finite(float(value)) \
				or float(value) < 0.0 or float(value) != floorf(float(value)):
			return _failure("invalid_number")
	if int(descriptor.run_generation) < 1:
		return _failure("invalid_number")
	if int(descriptor.previous_generation) >= int(descriptor.run_generation):
		return _failure("invalid_number")
	var digest: Variant = descriptor.content_digest
	if not digest is String or str(digest).length() != 64 or not str(digest).is_valid_hex_number():
		return _failure("invalid_digest")
	var endpoints: Variant = descriptor.endpoints
	if not endpoints is Array or endpoints.is_empty() or endpoints.size() > MAX_IDS:
		return _failure("invalid_endpoints")
	for endpoint: Variant in endpoints:
		if not endpoint is String or endpoint.is_empty() or endpoint.length() > MAX_ID_LENGTH:
			return _failure("invalid_endpoints")
	for key: String in ["issued_at", "expires_at"]:
		var value: Variant = descriptor.get(key)
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) < 0.0:
			return _failure("invalid_time")
	if float(descriptor.expires_at) <= float(descriptor.issued_at):
		return _failure("invalid_time")
	return {"ok": true, "reason": ""}


static func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
