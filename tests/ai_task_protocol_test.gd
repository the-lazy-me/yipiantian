extends SceneTree
## M9-02 headless fixture for the model task protocol. No model, network, disk,
## scene or clock: every time is injected and every response is fabricated.

const ModelTask = preload("res://ai/model_task.gd")

const NOW: float = 1800000000.0

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_create_round_trips()
	_test_create_rejections()
	_test_structural_rejections()
	_test_boundary_and_late_guards()
	_test_intent_responses()
	_test_text_responses()
	_test_response_rejections()
	_test_context_limits()
	for failure: String in failures:
		push_error(failure)
	print("AI_TASK_PROTOCOL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_create_round_trips() -> void:
	for type: String in [ModelTask.TYPE_INTENT, ModelTask.TYPE_DIALOGUE,
			ModelTask.TYPE_SUMMARY]:
		var result: Dictionary = ModelTask.create(_fields(type), NOW)
		_expect(result.ok, "A " + type + " task is created")
		var task: Dictionary = result.task
		_expect(task.size() == ModelTask.TASK_KEYS.size(),
			"A created task has exactly the protocol fields")
		_expect(task.id == "task-1" and task.type == type
			and task.world_id == "world-a" and task.state_version == "state-v1",
			"A created task keeps its identity, world and state version")
		_expect(task.created_utc == NOW and task.deadline_utc == NOW + 30.0,
			"The injected clock becomes created_utc and the deadline is preserved")
		_expect(task.cancel_id == task.id,
			"An omitted cancel_id defaults to the task id")
		_expect(ModelTask.valid(task), "A created " + type + " task is valid")
		if type == ModelTask.TYPE_INTENT:
			_expect(task.output_schema.intents.size() == 4
				and int(ModelTask.output_limit(task)) == 64,
				"The default intent schema lists the four intents with a 64-token cap")
		else:
			_expect(int(task.output_schema.max_tokens) == 120
				and int(ModelTask.output_limit(task)) == 120,
				"The default text schema has a 120-token cap")
	var subset: Dictionary = ModelTask.create(_fields("intent", {
		"output_schema": {"intents": ["trade", "work"]},
		"cancel_id": "cancel-1",
		"created_utc": NOW - 5.0,
	}), NOW)
	_expect(subset.ok and subset.task.output_schema.intents == ["trade", "work"]
		and subset.task.cancel_id == "cancel-1" and subset.task.created_utc == NOW - 5.0,
		"A caller can choose an intent subset, cancel id and earlier creation time")
	var narrow: Dictionary = ModelTask.create(_fields("dialogue", {
		"output_schema": {"max_tokens": 10},
	}), NOW)
	_expect(narrow.ok and int(ModelTask.output_limit(narrow.task)) == 10,
		"A text task can lower its own output cap")
	_expect(ModelTask.token_estimate("") == 0 and ModelTask.token_estimate("abc") == 1
		and ModelTask.token_estimate("abcd") == 2,
		"Token estimation is a deterministic UTF-8 byte bound")
	_expect(ModelTask.valid_time(0) and ModelTask.valid_time(1.5)
		and not ModelTask.valid_time(-1) and not ModelTask.valid_time(NAN)
		and not ModelTask.valid_time(INF) and not ModelTask.valid_time("1"),
		"Only finite non-negative numbers are valid times")


func _test_create_rejections() -> void:
	for type: Variant in ["other", "", 5, null]:
		_expect(_reason(ModelTask.create(_fields("dialogue", {"type": type}), NOW))
			== "unknown_type", "An unknown task type is refused")
	for bad_id: Variant in ["", "a".repeat(129), "bad\nid", 5]:
		_expect(_reason(ModelTask.create(_fields("dialogue", {"id": bad_id}), NOW))
			== "invalid_id", "An empty, oversized or control-character id is refused")
	_expect(_reason(ModelTask.create(_fields("dialogue", {"world_id": ""}), NOW))
		== "invalid_world", "An empty world id is refused")
	for bad_version: Variant in ["", "v".repeat(65), "bad\tversion", 7]:
		_expect(_reason(ModelTask.create(
			_fields("dialogue", {"state_version": bad_version}), NOW))
			== "invalid_state_version", "An invalid state version is refused")
	var missing_context: Dictionary = _fields("dialogue")
	missing_context.erase("visible_context")
	_expect(_reason(ModelTask.create(missing_context, NOW)) == "invalid_context",
		"A missing visible context is refused")
	_expect(_reason(ModelTask.create(
		_fields("dialogue", {"visible_context": "text"}), NOW)) == "invalid_context",
		"A non-dictionary visible context is refused")
	_expect(_reason(ModelTask.create(
		_fields("dialogue", {"visible_context": {"secret": 1}}), NOW))
		== "unknown_context_key", "An unknown visible-context field is refused")
	_expect(_reason(ModelTask.create(
		_fields("intent", {"output_schema": {"intents": ["hack"]}}), NOW))
		== "unknown_intent", "An intent outside the fixed enum is refused")
	_expect(_reason(ModelTask.create(
		_fields("intent", {"output_schema": {"intents": []}}), NOW))
		== "invalid_output_schema", "An empty intent list is refused")
	_expect(_reason(ModelTask.create(
		_fields("intent", {"output_schema": {"intents": ["greet", "greet"]}}), NOW))
		== "unknown_intent", "A duplicate intent is refused")
	_expect(_reason(ModelTask.create(
		_fields("intent", {"output_schema": {"intents": ["greet"], "extra": 1}}), NOW))
		== "invalid_output_schema", "An unknown output-schema field is refused")
	for bad_limit: Variant in [0, 121, 1.5, "10", -1]:
		_expect(_reason(ModelTask.create(
			_fields("dialogue", {"output_schema": {"max_tokens": bad_limit}}), NOW))
			== "invalid_output_limit", "An out-of-range text output cap is refused")
	_expect(_reason(ModelTask.create(
		_fields("dialogue", {"output_schema": {"other": 1}}), NOW))
		== "invalid_output_schema", "A text schema without max_tokens is refused")
	for bad_created: Variant in [-1, NAN, INF, NOW + 1.0]:
		_expect(_reason(ModelTask.create(
			_fields("dialogue", {"created_utc": bad_created}), NOW))
			== "invalid_created", "A negative, non-finite or future creation time is refused")
	_expect(_reason(ModelTask.create(_fields("dialogue", {
		"created_utc": NOW + 10.0, "deadline_utc": NOW + 20.0}), NOW))
		== "invalid_created", "A task created after the injected now is refused")
	var no_deadline: Dictionary = _fields("dialogue")
	no_deadline.erase("deadline_utc")
	_expect(_reason(ModelTask.create(no_deadline, NOW)) == "invalid_deadline",
		"A missing deadline is refused")
	for case: Dictionary in [
		{"created_utc": NOW - 10.0, "deadline_utc": NOW - 20.0},
		{"created_utc": NOW - 10.0, "deadline_utc": NOW - 10.0},
		{"created_utc": NOW - 10.0, "deadline_utc": NAN},
	]:
		_expect(_reason(ModelTask.create(_fields("dialogue", case), NOW))
			== "invalid_deadline", "A deadline not after creation is refused")
	_expect(_reason(ModelTask.create(_fields("dialogue", {
		"created_utc": NOW - 60.0, "deadline_utc": NOW}), NOW)) == "expired",
		"A task whose deadline has already arrived is refused as expired")
	for bad_cancel: Variant in ["", "c".repeat(129), "bad\ncancel", 5]:
		_expect(_reason(ModelTask.create(
			_fields("dialogue", {"cancel_id": bad_cancel}), NOW))
			== "invalid_cancel_id", "An invalid cancellation id is refused")
	_expect(_reason(ModelTask.create(_fields("dialogue", {"extra": true}), NOW))
		== "unknown_field", "An unknown top-level task field is refused")
	_expect(_reason(ModelTask.create("not a task", NOW)) == "invalid_task",
		"A non-dictionary task input is refused")
	_expect(_reason(ModelTask.create(_fields("dialogue"), -1.0)) == "invalid_time",
		"A negative injected clock is refused")


func _test_structural_rejections() -> void:
	var task: Dictionary = ModelTask.create(_fields("intent"), NOW).task
	var missing_cancel: Dictionary = task.duplicate(true)
	missing_cancel.erase("cancel_id")
	_expect(not ModelTask.valid(missing_cancel),
		"A stored task without a cancellation id is invalid")
	_expect(_reason(ModelTask.validate_structure(missing_cancel)) == "invalid_task",
		"Missing cancellation identity is reported as invalid_task")
	var empty_cancel: Dictionary = task.duplicate(true)
	empty_cancel.cancel_id = ""
	_expect(not ModelTask.valid(empty_cancel), "An empty stored cancel_id is invalid")
	var extra: Dictionary = task.duplicate(true)
	extra.action = "pay"
	_expect(_reason(ModelTask.validate_structure(extra)) == "unknown_field",
		"An unknown stored field is refused")
	_expect(not ModelTask.valid(null) and not ModelTask.valid([]),
		"Non-dictionary stored tasks are invalid")
	var bad_type: Dictionary = task.duplicate(true)
	bad_type.type = "other"
	_expect(_reason(ModelTask.validate_structure(bad_type)) == "unknown_type",
		"A stored unknown type is refused")
	var bad_deadline: Dictionary = task.duplicate(true)
	bad_deadline.deadline_utc = bad_deadline.created_utc
	_expect(_reason(ModelTask.validate_structure(bad_deadline)) == "invalid_deadline",
		"A stored deadline equal to creation is refused")
	var bad_context: Dictionary = task.duplicate(true)
	bad_context.visible_context = {"hidden": 1}
	_expect(_reason(ModelTask.validate_structure(bad_context)) == "unknown_context_key",
		"A stored unknown context field is refused")
	var bad_schema: Dictionary = task.duplicate(true)
	bad_schema.output_schema = {"max_tokens": 10}
	_expect(_reason(ModelTask.validate_structure(bad_schema))
		== "invalid_output_schema", "A stored intent task with a text schema is refused")


func _test_boundary_and_late_guards() -> void:
	var task: Dictionary = ModelTask.create(_fields("dialogue"), NOW).task
	_expect(ModelTask.validate(task, "world-a", "state-v1", NOW + 1.0).ok,
		"A matching world and state version pass")
	_expect(_reason(ModelTask.validate(task, "world-b", "state-v1", NOW + 1.0))
		== "cross_world", "A task from another world is refused")
	_expect(_reason(ModelTask.validate(task, "world-a", "state-v2", NOW + 1.0))
		== "state_version_mismatch", "A task from another state version is refused")
	_expect(ModelTask.expired(task, NOW + 30.0),
		"A task is expired exactly at its deadline")
	_expect(not ModelTask.expired(task, NOW + 29.999),
		"A task is not expired before its deadline")
	_expect(_reason(ModelTask.validate(task, "world-a", "state-v1", NOW + 30.0))
		== "expired", "An expired task fails the boundary check")
	_expect(ModelTask.cancelled(task, [task.cancel_id])
		and ModelTask.cancelled(task, {str(task.cancel_id): true})
		and not ModelTask.cancelled(task, [])
		and not ModelTask.cancelled(task, [str(task.cancel_id) + "-other"]),
		"Cancellation accepts array and dictionary id sets")
	_expect(_reason(ModelTask.validate(task, "world-a", "state-v1", NOW + 30.0,
		[task.cancel_id])) == "cancelled",
		"An explicitly cancelled task reports cancelled, not expired")
	_expect(ModelTask.expired(task, -1.0) and ModelTask.expired("not a task", NOW),
		"An invalid clock or task is treated as expired")
	_expect(not ModelTask.cancelled(task, "not-an-id-set"),
		"An unsupported cancellation set reports not cancelled")
	var late: Dictionary = ModelTask.accept(task, "world-a", "state-v1", "ok",
		NOW + 30.0, [task.cancel_id])
	_expect(not late.ok and not late.accepted and late.reason == "cancelled"
		and late.suggestion.is_empty(),
		"A late response after cancellation is refused without a suggestion")
	var stale: Dictionary = ModelTask.accept(task, "world-a", "state-v1", "ok",
		NOW + 31.0)
	_expect(not stale.ok and stale.reason == "expired",
		"A late response after the deadline is refused as expired")
	var foreign: Dictionary = ModelTask.accept(task, "world-b", "state-v1", "ok",
		NOW + 1.0)
	_expect(not foreign.ok and foreign.reason == "cross_world",
		"A response checked against another world is refused")
	var versioned: Dictionary = ModelTask.accept(task, "world-a", "state-v2", "ok",
		NOW + 1.0)
	_expect(not versioned.ok and versioned.reason == "state_version_mismatch",
		"A response checked against another state version is refused")


func _test_intent_responses() -> void:
	var task: Dictionary = ModelTask.create(_fields("intent"), NOW).task
	var before: Dictionary = task.duplicate(true)
	var response: Dictionary = {
		"intent": "greet", "confidence": 0.8, "reason": "林婶向玩家问好",
		"state_version": "state-v1",
	}
	var accepted: Dictionary = ModelTask.accept(
		task, "world-a", "state-v1", response, NOW + 1.0)
	_expect(accepted.ok and accepted.accepted
		and accepted.suggestion.intent == "greet"
		and accepted.suggestion.confidence == 0.8
		and accepted.suggestion.state_version == "state-v1",
		"A structured intent response becomes a suggestion")
	_expect(task == before, "Parsing a response never mutates the task")
	var text: Dictionary = ModelTask.accept(task, "world-a", "state-v1",
		JSON.stringify(response), NOW + 1.0)
	_expect(text.ok and text.suggestion.intent == "greet",
		"A JSON string intent response is parsed")
	var smuggled: Dictionary = ModelTask.accept(task, "world-a", "state-v1", {
		"intent": "trade", "state_version": "state-v1",
		"command": "pay", "world_mutation": {"cash": 999},
	}, NOW + 1.0)
	_expect(smuggled.ok and not smuggled.suggestion.has("command")
		and not smuggled.suggestion.has("world_mutation"),
		"Unknown response keys never enter the suggestion")
	var subset: Dictionary = ModelTask.create(_fields("intent", {
		"output_schema": {"intents": ["trade"]},
	}), NOW).task
	_expect(_reason(ModelTask.accept(subset, "world-a", "state-v1", {
		"intent": "greet", "state_version": "state-v1"}, NOW + 1.0))
		== "unknown_intent", "An intent outside the task's own enum is refused")
	_expect(ModelTask.accept(subset, "world-a", "state-v1", {
		"intent": "trade", "state_version": "state-v1"}, NOW + 1.0).ok,
		"An intent inside the task's own enum is accepted")


func _test_text_responses() -> void:
	var dialogue: Dictionary = ModelTask.create(_fields("dialogue"), NOW).task
	var plain: Dictionary = ModelTask.accept(
		dialogue, "world-a", "state-v1", "今天天气不错。", NOW + 1.0)
	_expect(plain.ok and plain.suggestion.text == "今天天气不错。",
		"Plain text dialogue becomes a text suggestion")
	var json_text: Dictionary = ModelTask.accept(dialogue, "world-a", "state-v1",
		{"text": "欢迎常来。"}, NOW + 1.0)
	_expect(json_text.ok and json_text.suggestion.text == "欢迎常来。",
		"A JSON dialogue response is parsed")
	var summary: Dictionary = ModelTask.create(_fields("summary"), NOW).task
	var summary_result: Dictionary = ModelTask.accept(
		summary, "world-a", "state-v1", "玩家昨天买了种子。", NOW + 1.0)
	_expect(summary_result.ok and summary_result.suggestion.text == "玩家昨天买了种子。",
		"A summary response becomes a text suggestion")
	var capped: Dictionary = ModelTask.create(_fields("dialogue", {
		"output_schema": {"max_tokens": 10},
	}), NOW).task
	_expect(ModelTask.accept(capped, "world-a", "state-v1", "a".repeat(30),
		NOW + 1.0).ok, "Text at the task output cap is accepted")
	_expect(_reason(ModelTask.accept(capped, "world-a", "state-v1",
		"a".repeat(31), NOW + 1.0)) == "output_too_long",
		"Text over the task output cap is refused")
	_expect(ModelTask.accept(dialogue, "world-a", "state-v1", "a".repeat(360),
		NOW + 1.0).ok, "Text at the default 120-token cap is accepted")
	_expect(_reason(ModelTask.accept(dialogue, "world-a", "state-v1",
		"a".repeat(361), NOW + 1.0)) == "output_too_long",
		"Text over the default 120-token cap is refused")


func _test_response_rejections() -> void:
	var intent: Dictionary = ModelTask.create(_fields("intent"), NOW).task
	var dialogue: Dictionary = ModelTask.create(_fields("dialogue"), NOW).task
	for bad_json: String in ["not json", "[]", "\"greet\"", "123"]:
		_expect(_reason(ModelTask.accept(intent, "world-a", "state-v1",
			bad_json, NOW + 1.0)) == "invalid_json",
			"An intent response that is not a JSON object is refused")
	_expect(_reason(ModelTask.accept(intent, "world-a", "state-v1", {
		"state_version": "state-v1"}, NOW + 1.0)) == "missing_intent",
		"A missing intent is refused")
	_expect(_reason(ModelTask.accept(intent, "world-a", "state-v1", {
		"intent": "hack", "state_version": "state-v1"}, NOW + 1.0))
		== "unknown_intent", "A response intent outside the enum is refused")
	_expect(_reason(ModelTask.accept(intent, "world-a", "state-v1", {
		"intent": "greet"}, NOW + 1.0)) == "missing_state_version",
		"An intent response without a state version is refused")
	_expect(_reason(ModelTask.accept(intent, "world-a", "state-v1", {
		"intent": "greet", "state_version": "state-v2"}, NOW + 1.0))
		== "state_version_mismatch",
		"An intent response carrying another state version is refused")
	for bad_confidence: Variant in [1.5, -0.1, "0.5", NAN, INF]:
		_expect(_reason(ModelTask.accept(intent, "world-a", "state-v1", {
			"intent": "greet", "state_version": "state-v1",
			"confidence": bad_confidence}, NOW + 1.0)) == "invalid_confidence",
			"An out-of-range or non-numeric confidence is refused")
	_expect(_reason(ModelTask.accept(intent, "world-a", "state-v1", {
		"intent": "greet", "state_version": "state-v1", "reason": 5}, NOW + 1.0))
		== "invalid_reason", "A non-text reason is refused")
	_expect(_reason(ModelTask.accept(intent, "world-a", "state-v1", {
		"intent": "greet", "state_version": "state-v1",
		"reason": "x".repeat(ModelTask.MAX_REASON_LENGTH + 1)}, NOW + 1.0))
		== "output_too_long", "An oversized intent reason is refused")
	_expect(_reason(ModelTask.accept(intent, "world-a", "state-v1", "",
		NOW + 1.0)) == "empty_response", "An empty response is refused")
	_expect(_reason(ModelTask.accept(dialogue, "world-a", "state-v1", "   ",
		NOW + 1.0)) == "empty_response", "A whitespace-only reply is refused")
	_expect(_reason(ModelTask.accept(dialogue, "world-a", "state-v1", 5,
		NOW + 1.0)) == "invalid_response", "A non-string non-object reply is refused")
	_expect(_reason(ModelTask.accept(dialogue, "world-a", "state-v1",
		{"other": "x"}, NOW + 1.0)) == "invalid_response",
		"A JSON reply without text is refused")
	_expect(_reason(ModelTask.accept(dialogue, "world-a", "state-v1",
		"a".repeat(ModelTask.MAX_RESPONSE_BYTES + 1), NOW + 1.0))
		== "response_too_long", "A response over the raw byte cap is refused")
	_expect(_reason(ModelTask.accept(intent, "world-a", "state-v1",
		"a".repeat(ModelTask.MAX_RESPONSE_BYTES + 1), NOW + 1.0))
		== "response_too_long", "An oversized intent response is refused")
	var missing: Dictionary = ModelTask.accept("not a task", "world-a", "state-v1",
		"ok", NOW + 1.0)
	_expect(not missing.ok and missing.reason == "invalid_task"
		and not missing.accepted and missing.suggestion.is_empty(),
		"An invalid task cannot accept a response")


func _test_context_limits() -> void:
	var at_limit: Dictionary = _fields("dialogue", {
		"visible_context": {"message": "a".repeat(8178)},
	})
	_expect(JSON.stringify(at_limit.visible_context).to_utf8_buffer().size() == 8192,
		"The exact context boundary fixture is 8192 bytes")
	_expect(ModelTask.create(at_limit, NOW).ok,
		"A visible context of exactly 8192 bytes is accepted")
	var over: Dictionary = _fields("dialogue", {
		"visible_context": {"message": "a".repeat(8179)},
	})
	_expect(_reason(ModelTask.create(over, NOW)) == "context_too_large",
		"A visible context one byte over the cap is refused")
	var unwritable: Dictionary = _fields("dialogue", {
		"visible_context": {"message": _opaque_value()},
	})
	_expect(_reason(ModelTask.create(unwritable, NOW)) == "invalid_context",
		"A visible context that cannot be serialized is refused")


func _opaque_value() -> Variant:
	return RefCounted.new()


func _fields(type: String, overrides: Dictionary = {}) -> Dictionary:
	var fields: Dictionary = {
		"id": "task-1",
		"type": type,
		"world_id": "world-a",
		"state_version": "state-v1",
		"visible_context": {"npc_id": "npc-lin", "message": "你好"},
		"deadline_utc": NOW + 30.0,
	}
	for key: Variant in overrides:
		fields[key] = overrides[key]
	return fields


func _reason(result: Dictionary) -> String:
	return str(result.get("reason", ""))


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
