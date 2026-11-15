extends RefCounted
## One wire budget for authority→member documents.
##
## A WebSocketMultiplayerPeer packet is capped at 65,535 bytes by default and
## put_packet() still reports OK when it drops one, so an oversized document
## never surfaces as an error at the call site. Every authority reply therefore
## passes this codec first: documents that fit the 48 KiB budget go out as
## plain JSON, larger ones travel as `z1:<raw_bytes>:<base64(zstd(json))>`.
## Compression that is still over budget is a named failure; the host refuses
## instead of calling rpc_id with a packet the transport would silently discard.
##
## The receiver trusts only the declared raw length and enforces it before and
## after decompression, so a damaged or hostile payload names its failure rather
## than producing an empty document.

const WIRE_BUDGET_BYTES: int = 48 * 1024
## Upper bound on one decoded document. Guards against a small compressed frame
## declaring a huge output length.
const CONTENT_MAX_BYTES: int = 2 * 1024 * 1024
const PREFIX: String = "z1:"


## True when `json` can be sent as it is or after compression.
static func fits(json: String) -> bool:
	return bool(encode(json).get("ok", false))


## Encodes one JSON document for the wire.
##
## Returns {ok, payload, raw_bytes, wire_bytes, compressed, reason}. An
## under-budget document stays plain JSON; an over-budget one is compressed and
## must still fit the budget. `ok=false` always carries the reason
## "payload_too_large" and an empty payload: the caller must not send it.
static func encode(json: String) -> Dictionary:
	var raw: PackedByteArray = json.to_utf8_buffer()
	var raw_size: int = raw.size()
	if raw_size <= WIRE_BUDGET_BYTES:
		return {
			"ok": true, "payload": json, "raw_bytes": raw_size,
			"wire_bytes": raw_size, "compressed": false,
		}
	if raw_size > CONTENT_MAX_BYTES:
		return {
			"ok": false, "reason": "payload_too_large", "payload": "",
			"raw_bytes": raw_size, "wire_bytes": raw_size, "compressed": false,
		}
	var compressed: PackedByteArray = raw.compress(FileAccess.COMPRESSION_ZSTD)
	var payload: String = "%s%d:%s" % [PREFIX, raw_size, Marshalls.raw_to_base64(compressed)]
	var encoded_size: int = payload.to_utf8_buffer().size()
	if encoded_size > WIRE_BUDGET_BYTES:
		return {
			"ok": false, "reason": "payload_too_large", "payload": "",
			"raw_bytes": raw_size, "wire_bytes": encoded_size, "compressed": true,
		}
	return {
		"ok": true, "payload": payload, "raw_bytes": raw_size,
		"wire_bytes": encoded_size, "compressed": true,
	}


## True when `document` names `reason` under either key. A refusal carries both,
## and a future sender may fill only one of them.
static func is_refusal(document: Dictionary, reason: String) -> bool:
	return str(document.get("error", "")) == reason \
		or str(document.get("reason", "")) == reason


## True when a summary reply is a visible refusal instead of a snapshot. Both
## cases are transient: the last confirmed state stays and the next reconcile
## asks again.
static func is_summary_refusal(document: Dictionary) -> bool:
	return is_refusal(document, "payload_too_large") \
		or is_refusal(document, "rate_limited")


## Decodes one wire payload back to JSON text.
##
## Returns {ok, text, raw_bytes, wire_bytes, compressed, reason}. Plain JSON is
## accepted only within the budget; a `z1:` document is validated structurally,
## bounded by CONTENT_MAX_BYTES, decompressed to exactly the declared length and
## rejected with a named reason otherwise. An empty document is a failure: the
## receiver must never replace a confirmed state with one.
static func decode(payload: String) -> Dictionary:
	var encoded_size: int = payload.to_utf8_buffer().size()
	if not payload.begins_with("z1"):
		if encoded_size > WIRE_BUDGET_BYTES:
			return _failure("payload_too_large", encoded_size, encoded_size, false)
		if payload.strip_edges().is_empty():
			return _failure("payload_decode_failed", encoded_size, encoded_size, false)
		return {
			"ok": true, "text": payload, "raw_bytes": encoded_size,
			"wire_bytes": encoded_size, "compressed": false,
		}
	if not payload.begins_with(PREFIX):
		return _failure("payload_invalid_prefix", encoded_size, -1, true)
	# The base64 alphabet has no colon, so at most three parts are meaningful.
	var parts: PackedStringArray = payload.split(":", true, 2)
	if parts.size() != 3:
		return _failure("payload_invalid_prefix", encoded_size, -1, true)
	var declared_text: String = parts[1]
	if not declared_text.is_valid_int():
		return _failure("payload_invalid_prefix", encoded_size, -1, true)
	var declared: int = declared_text.to_int()
	# A zero-length document is never a legitimate authority document.
	if declared <= 0 or declared > CONTENT_MAX_BYTES:
		return _failure(
			"payload_too_large" if declared > CONTENT_MAX_BYTES else "payload_decode_failed",
			encoded_size, declared, true)
	var compressed: PackedByteArray = Marshalls.base64_to_raw(parts[2])
	if compressed.is_empty() and declared > 0:
		return _failure("payload_decode_failed", encoded_size, declared, true)
	var raw: PackedByteArray = compressed.decompress(declared, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != declared:
		# A smaller declaration makes decompression fail outright; a larger one
		# decompresses normally and is caught by the length check.
		return _failure(
			"payload_decode_failed" if raw.is_empty() else "payload_length_mismatch",
			encoded_size, declared, true)
	return {
		"ok": true, "text": raw.get_string_from_utf8(), "raw_bytes": declared,
		"wire_bytes": encoded_size, "compressed": true,
	}


static func _failure(reason: String, encoded_size: int, raw_size: int,
		compressed: bool) -> Dictionary:
	return {
		"ok": false, "reason": reason, "text": "",
		"raw_bytes": raw_size, "wire_bytes": encoded_size, "compressed": compressed,
	}
