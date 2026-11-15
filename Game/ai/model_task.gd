extends RefCounted
## M9-02 model task protocol. Pure rules: no scene, disk, network, engine clock
## or world mutation. Callers inject `now_utc`; a model response is only ever
## returned as a `suggestion`, never applied to any world state.
##
## A task is a bounded, versioned request. `create` normalizes the caller's
## fields into exactly `TASK_KEYS`; `valid` checks a stored task without a
## clock; `expired`/`cancelled` are the two late-result guards; `accept` also
## checks the live world id and state version before parsing a response.
##
## Rejection reasons are stable strings:
##   unknown_type, invalid_id, invalid_world, invalid_state_version,
##   invalid_context, unknown_context_key, context_too_large,
##   invalid_output_schema, unknown_intent, invalid_output_limit,
##   invalid_created, invalid_deadline, invalid_cancel_id, unknown_field,
##   invalid_task, invalid_time, cross_world, state_version_mismatch,
##   cancelled, expired, invalid_response, empty_response, response_too_long,
##   invalid_json, missing_intent, missing_state_version, invalid_confidence,
##   invalid_reason, output_too_long.
##
## `cancel_id` is optional input: `create` defaults it to `id` so every stored
## task has a stable cancellation identity. A stored task missing it is invalid
## (`invalid_task`), which is the "missing cancellation identifier" guard.

const TYPE_INTENT: String = "intent"
const TYPE_DIALOGUE: String = "dialogue"
const TYPE_SUMMARY: String = "summary"
const TYPES: Array[String] = [TYPE_INTENT, TYPE_DIALOGUE, TYPE_SUMMARY]

## Fixed intent enum (the four benchmark classes in MODEL-CANDIDATES §3.3).
const INTENT_GREET: String = "greet"
const INTENT_TRADE: String = "trade"
const INTENT_WORK: String = "work"
const INTENT_CONFLICT: String = "conflict"
const INTENTS: Array[String] = [INTENT_GREET, INTENT_TRADE, INTENT_WORK, INTENT_CONFLICT]

## Fixed visible-context field allowlist. Anything else is refused so a caller
## cannot smuggle hidden state, instructions or action payloads into a prompt.
const CONTEXT_KEYS: Array[String] = [
	"npc_id", "npc_name", "player_id", "player_name", "location", "topic",
	"message", "nearby", "inventory", "prices", "relationship",
	"recent_events", "memories", "weather", "time_utc",
]

const TASK_KEYS: Array[String] = [
	"id", "type", "world_id", "state_version", "visible_context",
	"output_schema", "created_utc", "deadline_utc", "cancel_id",
]

const MAX_ID_LENGTH: int = 128
const MAX_WORLD_ID_LENGTH: int = 128
const MAX_STATE_VERSION_LENGTH: int = 64
const MAX_CANCEL_ID_LENGTH: int = 128
const MAX_REASON_LENGTH: int = 512
const MAX_CONTEXT_BYTES: int = 8192
const MAX_CONTEXT_DEPTH: int = 8
const MAX_RESPONSE_BYTES: int = 32768
## Deterministic token approximation: UTF-8 bytes / 3. There is no tokenizer in
## this pure slice; the cap is a bound, not a model-accurate count.
const BYTES_PER_TOKEN: int = 3

const OUTPUT_MAX_TOKENS: Dictionary = {
	TYPE_INTENT: 64,
	TYPE_DIALOGUE: 120,
	TYPE_SUMMARY: 120,
}


## Normalizes and validates caller fields. `created_utc` is optional and
## defaults to `now_utc`; `cancel_id` is optional and defaults to `id`;
## `output_schema` is optional and defaults to the full intent enum or the
## type's output cap.
static func create(fields: Variant, now_utc: float) -> Dictionary:
	if not fields is Dictionary:
		return _error("invalid_task")
	if not valid_time(now_utc):
		return _error("invalid_time")
	var input: Dictionary = fields
	for key: Variant in input:
		if not key is String or not TASK_KEYS.has(str(key)):
			return _error("unknown_field")
	if not _valid_text(input.get("id"), MAX_ID_LENGTH):
		return _error("invalid_id")
	var type: Variant = input.get("type")
	if not type is String or not TYPES.has(str(type)):
		return _error("unknown_type")
	if not _valid_text(input.get("world_id"), MAX_WORLD_ID_LENGTH):
		return _error("invalid_world")
	if not _valid_text(input.get("state_version"), MAX_STATE_VERSION_LENGTH):
		return _error("invalid_state_version")
	var created: Variant = input.get("created_utc", now_utc)
	if not valid_time(created) or float(created) > now_utc:
		return _error("invalid_created")
	var deadline: Variant = input.get("deadline_utc")
	if not valid_time(deadline) or float(deadline) <= float(created):
		return _error("invalid_deadline")
	if float(deadline) <= now_utc:
		return _error("expired")
	var context: Variant = input.get("visible_context")
	var context_reason: String = _context_reason(context)
	if not context_reason.is_empty():
		return _error(context_reason)
	var schema_result: Dictionary = _output_schema(str(type),
		input.get("output_schema", _default_schema(str(type))))
	if not schema_result.ok:
		return _error(str(schema_result.reason))
	var cancel_id: Variant = input.get("cancel_id", input.id)
	if not valid_cancel_id(cancel_id):
		return _error("invalid_cancel_id")
	var task: Dictionary = {
		"id": str(input.id),
		"type": str(type),
		"world_id": str(input.world_id),
		"state_version": str(input.state_version),
		"visible_context": (context as Dictionary).duplicate(true),
		"output_schema": (schema_result.schema as Dictionary).duplicate(true),
		"created_utc": float(created),
		"deadline_utc": float(deadline),
		"cancel_id": str(cancel_id),
	}
	var checked: Dictionary = validate_structure(task)
	if not checked.ok:
		return _error(str(checked.reason))
	return {"ok": true, "reason": "", "task": task}


## Structural and semantic validity with no clock. Covers types, bounds,
## visible-context keys/size, output schema, times and the cancel identifier.
static func validate_structure(task: Variant) -> Dictionary:
	if not task is Dictionary:
		return _error("invalid_task")
	var value: Dictionary = task
	for key: String in TASK_KEYS:
		if not value.has(key):
			return _error("invalid_task")
	for key: Variant in value:
		if not key is String or not TASK_KEYS.has(str(key)):
			return _error("unknown_field")
	if not _valid_text(value.id, MAX_ID_LENGTH):
		return _error("invalid_id")
	var type: Variant = value.type
	if not type is String or not TYPES.has(str(type)):
		return _error("unknown_type")
	if not _valid_text(value.world_id, MAX_WORLD_ID_LENGTH):
		return _error("invalid_world")
	if not _valid_text(value.state_version, MAX_STATE_VERSION_LENGTH):
		return _error("invalid_state_version")
	var context_reason: String = _context_reason(value.visible_context)
	if not context_reason.is_empty():
		return _error(context_reason)
	var schema_result: Dictionary = _output_schema(str(type), value.output_schema)
	if not schema_result.ok:
		return _error(str(schema_result.reason))
	if not valid_time(value.created_utc) or not valid_time(value.deadline_utc):
		return _error("invalid_deadline")
	if float(value.deadline_utc) <= float(value.created_utc):
		return _error("invalid_deadline")
	if not valid_cancel_id(value.cancel_id):
		return _error("invalid_cancel_id")
	return {"ok": true, "reason": ""}


static func valid(task: Variant) -> bool:
	return validate_structure(task).ok


## Late-result guard: a task at or past its deadline is expired.
static func expired(task: Variant, now_utc: float) -> bool:
	if not task is Dictionary or not valid_time(now_utc):
		return true
	if not valid_time(task.get("deadline_utc")):
		return true
	return now_utc >= float(task.deadline_utc)


## `cancelled_ids` may be an Array of ids or a Dictionary keyed by id.
static func cancelled(task: Variant, cancelled_ids: Variant = []) -> bool:
	if not task is Dictionary:
		return false
	var cancel_id: Variant = task.get("cancel_id")
	if not valid_cancel_id(cancel_id):
		return false
	var id: String = str(cancel_id)
	if cancelled_ids is Dictionary:
		return cancelled_ids.has(id)
	if cancelled_ids is Array:
		return cancelled_ids.has(id)
	return false


## Full boundary check used by the scheduler and by `accept`: structure, world,
## state version, cancellation, then expiry. Cancellation wins over expiry when
## both are true because the caller explicitly withdrew the task.
static func validate(task: Variant, world_id: String, state_version: String,
		now_utc: float, cancelled_ids: Variant = []) -> Dictionary:
	var structural: Dictionary = validate_structure(task)
	if not structural.ok:
		return structural
	if not valid_time(now_utc):
		return _error("invalid_time")
	if str(task.world_id) != str(world_id):
		return _error("cross_world")
	if str(task.state_version) != str(state_version):
		return _error("state_version_mismatch")
	if cancelled(task, cancelled_ids):
		return _error("cancelled")
	if expired(task, now_utc):
		return _error("expired")
	return {"ok": true, "reason": ""}


## Parses a model response into a suggestion. The task and the world are never
## modified. JSON is accepted for every type; plain text is accepted only for
## `dialogue`/`summary`. An `intent` response must hit the task's enum and carry
## the task's `state_version`.
static func accept(task: Variant, world_id: String, state_version: String,
		response: Variant, now_utc: float, cancelled_ids: Variant = []) -> Dictionary:
	var checked: Dictionary = validate(task, world_id, state_version, now_utc, cancelled_ids)
	if not checked.ok:
		return _accept_error(str(checked.reason))
	var parsed: Dictionary = _parse_response(task, response)
	if not parsed.ok:
		return _accept_error(str(parsed.reason))
	return {
		"ok": true, "accepted": true, "suggestion": parsed.suggestion, "reason": "",
	}


static func output_limit(task: Variant) -> int:
	if not task is Dictionary:
		return 0
	if str(task.get("type", "")) == TYPE_INTENT:
		return int(OUTPUT_MAX_TOKENS[TYPE_INTENT])
	var schema: Variant = task.get("output_schema")
	if schema is Dictionary and schema.get("max_tokens") is int:
		return int(schema.max_tokens)
	return 0


static func token_estimate(text: String) -> int:
	var bytes: int = text.to_utf8_buffer().size()
	return int(ceil(float(bytes) / float(BYTES_PER_TOKEN)))


static func valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0


static func valid_cancel_id(value: Variant) -> bool:
	return _valid_text(value, MAX_CANCEL_ID_LENGTH)


static func _parse_response(task: Dictionary, response: Variant) -> Dictionary:
	var type: String = str(task.type)
	var object: Variant = null
	if response is String:
		var raw: String = str(response)
		if raw.to_utf8_buffer().size() > MAX_RESPONSE_BYTES:
			return _error("response_too_long")
		var trimmed: String = raw.strip_edges()
		if trimmed.is_empty():
			return _error("empty_response")
		# Only a leading `{` is treated as a JSON object. Other text is plain
		# text (dialogue/summary) or invalid JSON (intent), so a normal Chinese
		# reply never reaches the JSON parser as an error.
		if trimmed.begins_with("{"):
			# Use an explicit parser: `JSON.parse_string` logs an engine ERROR
			# for every malformed adversarial reply, which floods diagnostics
			# even though the protocol reason is already stable.
			var parser: JSON = JSON.new()
			var decoded: Variant = null
			if parser.parse(trimmed) == OK:
				decoded = parser.data
			if decoded is Dictionary:
				object = decoded
			elif type == TYPE_INTENT:
				return _error("invalid_json")
			else:
				return _error("invalid_response")
		elif type == TYPE_INTENT:
			return _error("invalid_json")
	elif response is Dictionary:
		object = response
	else:
		return _error("invalid_response")

	if type == TYPE_INTENT:
		return _parse_intent(task, object, response)
	return _parse_text(task, object, response)


static func _parse_intent(task: Dictionary, object: Variant, response: Variant) -> Dictionary:
	if not object is Dictionary:
		return _error("invalid_json")
	var payload: Dictionary = object
	var allowed: Array = task.output_schema.intents
	var intent: Variant = payload.get("intent")
	if not intent is String:
		return _error("missing_intent")
	if not allowed.has(str(intent)) or not INTENTS.has(str(intent)):
		return _error("unknown_intent")
	var response_version: Variant = payload.get("state_version")
	if not response_version is String or str(response_version).is_empty():
		return _error("missing_state_version")
	if str(response_version) != str(task.state_version):
		return _error("state_version_mismatch")
	var confidence: float = 0.0
	if payload.has("confidence"):
		var raw_confidence: Variant = payload.confidence
		if not (raw_confidence is int or raw_confidence is float) \
				or not is_finite(float(raw_confidence)) \
				or float(raw_confidence) < 0.0 or float(raw_confidence) > 1.0:
			return _error("invalid_confidence")
		confidence = float(raw_confidence)
	var reason: String = ""
	if payload.has("reason"):
		if not payload.reason is String:
			return _error("invalid_reason")
		reason = str(payload.reason)
		if reason.length() > MAX_REASON_LENGTH:
			return _error("output_too_long")
	var suggestion: Dictionary = {
		"intent": str(intent),
		"confidence": confidence,
		"reason": reason,
		"state_version": str(response_version),
	}
	if token_estimate(JSON.stringify(suggestion)) > output_limit(task):
		return _error("output_too_long")
	return {"ok": true, "reason": "", "suggestion": suggestion}


static func _parse_text(task: Dictionary, object: Variant, response: Variant) -> Dictionary:
	var text: String = ""
	if object is Dictionary:
		var payload: Dictionary = object
		if not payload.get("text") is String:
			return _error("invalid_response")
		text = str(payload.text)
	elif response is String:
		text = str(response)
	else:
		return _error("invalid_response")
	if text.strip_edges().is_empty():
		return _error("empty_response")
	if token_estimate(text) > output_limit(task):
		return _error("output_too_long")
	return {"ok": true, "reason": "", "suggestion": {"text": text}}


static func _default_schema(type: String) -> Dictionary:
	if type == TYPE_INTENT:
		return {"intents": INTENTS.duplicate()}
	return {"max_tokens": int(OUTPUT_MAX_TOKENS[type])}


static func _output_schema(type: String, value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _error("invalid_output_schema")
	var schema: Dictionary = value
	if type == TYPE_INTENT:
		if schema.size() != 1 or not schema.has("intents"):
			return _error("invalid_output_schema")
		var intents: Variant = schema.intents
		if not intents is Array or intents.is_empty() or intents.size() > INTENTS.size():
			return _error("invalid_output_schema")
		var seen: Dictionary = {}
		var accepted: Array[String] = []
		for raw_intent: Variant in intents:
			if not raw_intent is String or not INTENTS.has(str(raw_intent)) \
					or seen.has(str(raw_intent)):
				return _error("unknown_intent")
			seen[str(raw_intent)] = true
			accepted.append(str(raw_intent))
		return {"ok": true, "reason": "", "schema": {"intents": accepted}}
	if schema.size() != 1 or not schema.has("max_tokens"):
		return _error("invalid_output_schema")
	var raw_limit: Variant = schema.max_tokens
	if not raw_limit is int or int(raw_limit) < 1 \
			or int(raw_limit) > int(OUTPUT_MAX_TOKENS[type]):
		return _error("invalid_output_limit")
	return {"ok": true, "reason": "", "schema": {"max_tokens": int(raw_limit)}}


static func _context_reason(value: Variant) -> String:
	if not value is Dictionary:
		return "invalid_context"
	var context: Dictionary = value
	for key: Variant in context:
		if not key is String or not CONTEXT_KEYS.has(str(key)):
			return "unknown_context_key"
	if not _json_safe(context, 0):
		return "invalid_context"
	var encoded: String = JSON.stringify(context)
	if encoded.is_empty() and not context.is_empty():
		return "invalid_context"
	if encoded.to_utf8_buffer().size() > MAX_CONTEXT_BYTES:
		return "context_too_large"
	return ""


## Only JSON-compatible data may enter a prompt. Objects, callables, RIDs,
## non-string dictionary keys and non-finite numbers are refused, and nesting is
## bounded so serialization cannot recurse without limit.
static func _json_safe(value: Variant, depth: int) -> bool:
	if depth > MAX_CONTEXT_DEPTH:
		return false
	if value == null:
		return true
	if value is bool or value is int or value is String:
		return true
	if value is float:
		return is_finite(float(value))
	if value is Array:
		for item: Variant in value:
			if not _json_safe(item, depth + 1):
				return false
		return true
	if value is Dictionary:
		for key: Variant in value:
			if not key is String or not _json_safe(value[key], depth + 1):
				return false
		return true
	return false


static func _valid_text(value: Variant, max_length: int) -> bool:
	if not value is String:
		return false
	var text: String = str(value)
	if text.is_empty() or text.length() > max_length:
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		if code < 32 or code == 127:
			return false
	return true


static func _error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


static func _accept_error(reason: String) -> Dictionary:
	return {"ok": false, "accepted": false, "suggestion": {}, "reason": reason}
