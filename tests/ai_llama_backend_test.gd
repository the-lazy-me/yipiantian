extends SceneTree
## M9-04 headless fixture for the optional llama.cpp backend. Normal runs use a
## fake OS runner: no model, no disk, no real subprocess. The real binary and
## model are exercised only when YIPIANTIAN_LLAMA_SMOKE=1 and both explicit
## paths are provided.

const ModelTask = preload("res://ai/model_task.gd")
const Scheduler = preload("res://ai/model_scheduler.gd")
const Backend = preload("res://ai/llama_cpp_backend.gd")

const NOW: float = 1800000000.0
const BIN_PATH: String = "/fake/llama-cli"
const MODEL_PATH: String = "/fake/model.gguf"

var checks: int = 0
var failures: Array[String] = []


class Clock:
	var ms: float = 0.0


class FakeRunner:
	var exists_map: Dictionary = {}
	var spawn_ok: bool = true
	var spawn_calls: int = 0
	var kill_calls: int = 0
	var last_path: String = ""
	var last_args: PackedStringArray = PackedStringArray()
	var poll_script: Array = []
	var default_poll: Dictionary = {
		"ok": true, "stdout": PackedByteArray(), "stderr": PackedByteArray(),
		"running": true, "exit_code": -1,
	}

	func exists(path: String) -> bool:
		return bool(exists_map.get(path, false))

	func spawn(path: String, arguments: PackedStringArray) -> Dictionary:
		spawn_calls += 1
		last_path = path
		last_args = arguments.duplicate()
		if not spawn_ok:
			return {"ok": false, "reason": "spawn_failed"}
		return {"ok": true, "handle": {"pid": 4242}}

	func poll(_handle: Dictionary) -> Variant:
		if poll_script.is_empty():
			return default_poll.duplicate(true)
		return poll_script.pop_front()

	func kill(_handle: Dictionary) -> void:
		kill_calls += 1


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_disabled_and_missing()
	_test_success_and_prompt()
	_test_think_strip_and_intent()
	_test_nonzero_exit()
	_test_timeout()
	_test_output_too_long()
	_test_runner_failures()
	_test_scheduler_cancel_timeout_disable()
	_test_scheduler_completion()
	_test_load_failure_detail()
	_test_real_smoke()
	for failure: String in failures:
		push_error(failure)
	print("AI_LLAMA_BACKEND_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_disabled_and_missing() -> void:
	var off := Backend.new()
	_expect(not off.enabled and not off.loaded(),
		"The backend is disabled and not loaded by default")
	var off_load: Dictionary = off.load()
	_expect(not off_load.ok and off_load.reason == "disabled",
		"A disabled backend refuses to load without touching the OS")
	_expect(off.generate(_task(ModelTask.TYPE_DIALOGUE)).reason == "disabled",
		"A disabled backend refuses generation")

	var runner := FakeRunner.new()
	var clock := Clock.new()
	var backend: Backend = _backend(runner, clock)
	runner.exists_map[BIN_PATH] = false
	var missing_bin: Dictionary = backend.load()
	_expect(not missing_bin.ok and missing_bin.reason == "binary_missing"
		and missing_bin.detail == BIN_PATH and runner.spawn_calls == 0,
		"A missing binary is diagnosed without spawning")
	runner.exists_map[BIN_PATH] = true
	runner.exists_map[MODEL_PATH] = false
	var missing_model: Dictionary = backend.load()
	_expect(not missing_model.ok and missing_model.reason == "model_missing"
		and missing_model.detail == MODEL_PATH and runner.spawn_calls == 0,
		"A missing model is diagnosed without spawning")
	runner.exists_map[MODEL_PATH] = true
	var loaded: Dictionary = backend.load()
	_expect(loaded.ok and backend.loaded(), "Explicit paths load the backend")
	var started: Dictionary = backend.generate(_task(ModelTask.TYPE_DIALOGUE))
	_expect(started.ok and bool(started.get("pending", false))
		and runner.spawn_calls == 1,
		"Generation starts exactly one process and returns pending")
	_expect(backend.generate(_task(ModelTask.TYPE_DIALOGUE)).reason == "busy",
		"A second generation while one process runs is refused")
	backend.abort()
	_expect(runner.kill_calls == 1 and not backend.status().running,
		"Abort kills and clears the running process")
	backend.unload()
	_expect(not backend.loaded(), "Unload marks the backend unloaded")


func _test_success_and_prompt() -> void:
	var runner := FakeRunner.new()
	var clock := Clock.new()
	var backend: Backend = _backend(runner, clock)
	_expect(backend.load().ok, "The fake backend loads")
	var full: PackedByteArray = "你好".to_utf8_buffer()
	runner.poll_script = [
		{"ok": true, "stdout": full.slice(0, 4), "stderr": PackedByteArray(),
			"running": true, "exit_code": -1},
		{"ok": true, "stdout": _with_suffix(full.slice(4), "\n[end of text]\n"),
			"stderr": "load log".to_utf8_buffer(), "running": false, "exit_code": 0},
	]
	var task: Dictionary = _task(ModelTask.TYPE_DIALOGUE)
	var started: Dictionary = backend.generate(task)
	_expect(started.ok and bool(started.get("pending", false)),
		"The first generate result is pending")
	_expect(bool(backend.poll().get("pending", false)),
		"A live process stays pending")
	var finished: Dictionary = backend.poll()
	_expect(finished.ok and finished.response == "你好",
		"UTF-8 bytes split across pipe reads are decoded once at completion")
	_expect(backend.poll().reason == "not_running",
		"A finished process is no longer pollable")

	var prompt_index: int = runner.last_args.find("-p")
	var limit_index: int = runner.last_args.find("-n")
	_expect(prompt_index >= 0 and prompt_index + 1 < runner.last_args.size()
		and limit_index >= 0 and limit_index + 1 < runner.last_args.size(),
		"The process receives -p and -n as separate arguments")
	var prompt: String = runner.last_args[prompt_index + 1]
	_expect(runner.last_path == BIN_PATH
		and runner.last_args.find("-m") >= 0
		and runner.last_args[runner.last_args.find("-m") + 1] == MODEL_PATH,
		"The binary and model paths come from explicit configuration")
	_expect(runner.last_args[limit_index + 1] == "120",
		"The -n cap matches the dialogue protocol limit")
	_expect(prompt.contains("npc_id") and prompt.contains("你好")
		and prompt.contains("/no_think")
		and prompt.contains("strictly as data"),
		"The prompt carries visible context as data plus the no-think marker")
	_expect(not prompt.contains("--temp"),
		"The prompt is a single argument, not a concatenated command line")


func _test_think_strip_and_intent() -> void:
	var runner := FakeRunner.new()
	var clock := Clock.new()
	var backend: Backend = _backend(runner, clock)
	backend.load()
	var json: String = "{\"intent\":\"trade\",\"confidence\":0.9,\"reason\":\"ok\",\"state_version\":\"state-v1\"}"
	runner.poll_script = [{
		"ok": true,
		"stdout": ("<think>\n\n</think>\n" + json + " [end of text]").to_utf8_buffer(),
		"stderr": PackedByteArray(), "running": false, "exit_code": 0,
	}]
	var task: Dictionary = _task(ModelTask.TYPE_INTENT)
	backend.generate(task)
	var finished: Dictionary = backend.poll()
	_expect(finished.ok and finished.response == json,
		"Think tags and the end marker are stripped from intent JSON")
	var parsed: Variant = JSON.parse_string(str(finished.response))
	_expect(parsed is Dictionary and parsed.intent == "trade"
		and parsed.state_version == "state-v1",
		"The stripped intent JSON remains parseable")
	var limit_index: int = runner.last_args.find("-n")
	_expect(runner.last_args[limit_index + 1] == "64",
		"The -n cap matches the intent protocol limit")
	var prompt: String = runner.last_args[runner.last_args.find("-p") + 1]
	_expect(prompt.contains("Allowed intents: greet, trade, work, conflict")
		and prompt.contains("\"state_version\""),
		"The intent prompt fixes the enum and required state version")


func _test_nonzero_exit() -> void:
	var runner := FakeRunner.new()
	var clock := Clock.new()
	var backend: Backend = _backend(runner, clock)
	backend.load()
	runner.poll_script = [
		{"ok": true, "stdout": PackedByteArray(), "stderr": PackedByteArray(),
			"running": true, "exit_code": -1},
		{"ok": true, "stdout": PackedByteArray(),
			"stderr": "model load failed".to_utf8_buffer(),
			"running": false, "exit_code": 7},
	]
	backend.generate(_task(ModelTask.TYPE_DIALOGUE))
	backend.poll()
	var failed: Dictionary = backend.poll()
	_expect(not failed.ok and failed.reason == "process_exit"
		and str(failed.detail).contains("exit_code=7")
		and str(failed.detail).contains("model load failed"),
		"A non-zero exit reports its code and stderr tail")
	_expect(not backend.status().running and runner.kill_calls == 0,
		"An exited process is cleared without an extra kill")


func _test_timeout() -> void:
	var runner := FakeRunner.new()
	var clock := Clock.new()
	var backend: Backend = _backend(runner, clock, {"timeout_seconds": 1.0})
	backend.load()
	backend.generate(_task(ModelTask.TYPE_DIALOGUE))
	clock.ms = 500.0
	_expect(bool(backend.poll().get("pending", false)),
		"A process below the hard timeout stays pending")
	clock.ms = 1000.0
	var timed_out: Dictionary = backend.poll()
	_expect(not timed_out.ok and timed_out.reason == "timeout"
		and runner.kill_calls == 1,
		"Reaching the backend hard timeout kills the process")
	_expect(backend.poll().reason == "not_running",
		"A timed-out process is cleared")


func _test_output_too_long() -> void:
	var runner := FakeRunner.new()
	var clock := Clock.new()
	var backend: Backend = _backend(runner, clock, {"max_output_bytes": 8})
	backend.load()
	runner.poll_script = [{
		"ok": true, "stdout": "0123456789abcdef".to_utf8_buffer(),
		"stderr": PackedByteArray(), "running": true, "exit_code": -1,
	}]
	backend.generate(_task(ModelTask.TYPE_DIALOGUE))
	var too_long: Dictionary = backend.poll()
	_expect(not too_long.ok and too_long.reason == "output_too_long"
		and too_long.detail == "16" and runner.kill_calls == 1,
		"Output over the byte cap kills the process and is refused")


func _test_runner_failures() -> void:
	var runner := FakeRunner.new()
	var clock := Clock.new()
	var backend: Backend = _backend(runner, clock)
	backend.load()
	runner.spawn_ok = false
	var spawn_failed: Dictionary = backend.generate(_task(ModelTask.TYPE_DIALOGUE))
	_expect(not spawn_failed.ok and spawn_failed.reason == "process_failed"
		and spawn_failed.detail == "spawn_failed",
		"A spawn failure is reported without a running process")
	_expect(backend.poll().reason == "not_running",
		"A failed spawn leaves nothing to poll")

	var empty_runner := FakeRunner.new()
	var empty_backend: Backend = _backend(empty_runner, Clock.new())
	empty_backend.load()
	empty_runner.poll_script = [{
		"ok": true, "stdout": PackedByteArray(), "stderr": PackedByteArray(),
		"running": false, "exit_code": 0,
	}]
	empty_backend.generate(_task(ModelTask.TYPE_DIALOGUE))
	_expect(empty_backend.poll().reason == "empty_output",
		"A clean exit without output is refused as empty")

	var bad_runner := FakeRunner.new()
	var bad_backend: Backend = _backend(bad_runner, Clock.new())
	bad_backend.load()
	bad_runner.poll_script = [42]
	bad_backend.generate(_task(ModelTask.TYPE_DIALOGUE))
	_expect(bad_backend.poll().reason == "process_failed"
		and bad_runner.kill_calls == 1,
		"An invalid runner result is a process failure and kills the process")


func _test_scheduler_cancel_timeout_disable() -> void:
	var runner := FakeRunner.new()
	var backend: Backend = _backend(runner, Clock.new())
	var scheduler := Scheduler.new(backend, "world-a", "state-v1")
	var task: Dictionary = _task(ModelTask.TYPE_DIALOGUE, {"deadline_utc": NOW + 60.0})
	scheduler.submit(task, NOW)
	_expect(scheduler.poll(NOW).status == "waiting" and runner.spawn_calls == 1,
		"The scheduler starts the real backend lazily")
	var cancelled: Dictionary = scheduler.cancel(task.cancel_id, NOW + 1.0)
	_expect(cancelled.cancelled == 1 and runner.kill_calls == 1
		and not backend.status().running,
		"Scheduler cancellation aborts the in-flight process")
	_expect(scheduler.poll(NOW + 1.0).status == "idle"
		and runner.spawn_calls == 1,
		"A cancelled process is not restarted")

	var timeout_runner := FakeRunner.new()
	var timeout_backend: Backend = _backend(timeout_runner, Clock.new())
	var timeout_scheduler := Scheduler.new(timeout_backend, "world-a", "state-v1")
	var timeout_task: Dictionary = _task(ModelTask.TYPE_DIALOGUE,
		{"deadline_utc": NOW + 5.0})
	timeout_scheduler.submit(timeout_task, NOW)
	_expect(timeout_scheduler.poll(NOW).status == "waiting",
		"The scheduler starts a task with a deadline")
	var timed_out: Dictionary = timeout_scheduler.poll(NOW + 5.0)
	_expect(timed_out.status == "timeout" and timeout_runner.kill_calls == 1,
		"A scheduler deadline timeout aborts the process")

	var off_runner := FakeRunner.new()
	var off_backend: Backend = _backend(off_runner, Clock.new())
	var off_scheduler := Scheduler.new(off_backend, "world-a", "state-v1")
	off_scheduler.submit(_task(ModelTask.TYPE_DIALOGUE), NOW)
	off_scheduler.poll(NOW)
	var disabled: Dictionary = off_scheduler.set_enabled(false, NOW + 1.0)
	_expect(disabled.ok and disabled.unloaded and off_runner.kill_calls == 1
		and not off_backend.status().running,
		"Disabling the scheduler aborts and unloads the backend")


func _test_scheduler_completion() -> void:
	var runner := FakeRunner.new()
	var backend: Backend = _backend(runner, Clock.new())
	var scheduler := Scheduler.new(backend, "world-a", "state-v1")
	var json: String = "{\"intent\":\"work\",\"confidence\":0.7,\"reason\":\"ok\",\"state_version\":\"state-v1\"}"
	runner.poll_script = [{
		"ok": true, "stdout": json.to_utf8_buffer(),
		"stderr": PackedByteArray(), "running": false, "exit_code": 0,
	}]
	var intent_task: Dictionary = _task(ModelTask.TYPE_INTENT)
	scheduler.submit(intent_task, NOW)
	_expect(scheduler.poll(NOW).status == "waiting",
		"The scheduler polls the backend while a process runs")
	var completed: Dictionary = scheduler.poll(NOW + 1.0)
	_expect(completed.ok and completed.status == "completed"
		and completed.accepted and completed.suggestion.intent == "work",
		"A backend response still passes through the protocol as a suggestion")

	var text_runner := FakeRunner.new()
	var text_backend: Backend = _backend(text_runner, Clock.new())
	var text_scheduler := Scheduler.new(text_backend, "world-a", "state-v1")
	text_runner.poll_script = [{
		"ok": true, "stdout": "你好，今天青菜很新鲜。".to_utf8_buffer(),
		"stderr": PackedByteArray(), "running": false, "exit_code": 0,
	}]
	text_scheduler.submit(_task(ModelTask.TYPE_DIALOGUE), NOW)
	text_scheduler.poll(NOW)
	var text_done: Dictionary = text_scheduler.poll(NOW + 1.0)
	_expect(text_done.ok and text_done.status == "completed"
		and text_done.suggestion.text == "你好，今天青菜很新鲜。",
		"Plain dialogue text becomes a suggestion, not a world change")


func _test_load_failure_detail() -> void:
	var runner := FakeRunner.new()
	var clock := Clock.new()
	var backend: Backend = _backend(runner, clock)
	runner.exists_map[MODEL_PATH] = false
	var scheduler := Scheduler.new(backend, "world-a", "state-v1")
	scheduler.submit(_task(ModelTask.TYPE_DIALOGUE), NOW)
	var failed: Dictionary = scheduler.poll(NOW)
	_expect(failed.status == "load_failed" and failed.detail == "model_missing"
		and runner.spawn_calls == 0,
		"A backend load reason survives the scheduler boundary")
	var off_scheduler := Scheduler.new(Backend.new(), "world-a", "state-v1")
	off_scheduler.submit(_task(ModelTask.TYPE_DIALOGUE), NOW)
	_expect(off_scheduler.poll(NOW).detail == "disabled",
		"A disabled backend is diagnosed as disabled by the scheduler")


## Real process smoke. Off unless explicitly enabled; requires both paths.
func _test_real_smoke() -> void:
	if OS.get_environment("YIPIANTIAN_LLAMA_SMOKE") != "1":
		return
	var binary_path: String = OS.get_environment("YIPIANTIAN_LLAMA_BIN")
	var model_path: String = OS.get_environment("YIPIANTIAN_LLAMA_MODEL")
	_expect(not binary_path.is_empty() and not model_path.is_empty(),
		"The real smoke needs YIPIANTIAN_LLAMA_BIN and YIPIANTIAN_LLAMA_MODEL")
	if binary_path.is_empty() or model_path.is_empty():
		return
	var backend := Backend.new({
		"enabled": true,
		"binary_path": binary_path,
		"model_path": model_path,
		"timeout_seconds": 180.0,
	})
	var loaded: Dictionary = backend.load()
	_expect(loaded.ok, "The real llama.cpp backend loads: " + str(loaded))
	if not loaded.ok:
		return
	var now: float = Time.get_unix_time_from_system()
	var created: Dictionary = ModelTask.create({
		"id": "real-smoke-1",
		"type": ModelTask.TYPE_INTENT,
		"world_id": "world-a",
		"state_version": "state-v1",
		"visible_context": {
			"npc_id": "npc-lin",
			"message": "邻居询问青菜价格并表示购买意图",
		},
		"deadline_utc": now + 240.0,
	}, now)
	_expect(created.ok, "The real smoke task is valid")
	if not created.ok:
		return
	var scheduler := Scheduler.new(backend, "world-a", "state-v1")
	scheduler.submit(created.task, now)
	var result: Dictionary = {}
	var stop_ms: int = Time.get_ticks_msec() + 240000
	while Time.get_ticks_msec() < stop_ms:
		result = scheduler.poll(Time.get_unix_time_from_system())
		if result.get("status", "") != "waiting" \
				and result.get("status", "") != "idle":
			break
		OS.delay_msec(200)
	_expect(result.get("status", "") == "completed",
		"The real model completes an intent task: " + str(result))
	if result.get("status", "") == "completed":
		var suggestion: Dictionary = result.get("suggestion", {})
		_expect(ModelTask.INTENTS.has(str(suggestion.get("intent", "")))
			and str(suggestion.get("state_version", "")) == "state-v1",
			"The real model returns a legal intent and state version")
		print("LLAMA_REAL_SMOKE intent=%s confidence=%s reason=%s"
			% [str(suggestion.get("intent", "")),
				str(suggestion.get("confidence", "")),
				str(suggestion.get("reason", ""))])


func _backend(runner: FakeRunner, clock: Clock, options: Dictionary = {}) -> Backend:
	runner.exists_map[BIN_PATH] = true
	runner.exists_map[MODEL_PATH] = true
	var config: Dictionary = {
		"enabled": true,
		"binary_path": BIN_PATH,
		"model_path": MODEL_PATH,
		"runner": runner,
		"clock": func() -> float: return clock.ms,
	}
	for key: Variant in options:
		config[key] = options[key]
	return Backend.new(config)


func _task(type: String, overrides: Dictionary = {}) -> Dictionary:
	var fields: Dictionary = {
		"id": "task-1",
		"type": type,
		"world_id": "world-a",
		"state_version": "state-v1",
		"visible_context": {"npc_id": "npc-lin", "message": "你好"},
		"deadline_utc": NOW + 100.0,
	}
	for key: Variant in overrides:
		fields[key] = overrides[key]
	var result: Dictionary = ModelTask.create(fields, NOW)
	if not result.ok:
		failures.append("fixture task was refused: " + str(result.reason))
		checks += 1
		return {}
	return result.task


func _with_suffix(bytes: PackedByteArray, suffix: String) -> PackedByteArray:
	var result: PackedByteArray = bytes.duplicate()
	result.append_array(suffix.to_utf8_buffer())
	return result


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
