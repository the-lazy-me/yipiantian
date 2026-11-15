extends SceneTree
## M9-03 headless fixture for the single-queue scheduler. A fake in-process
## backend stands in for any model; there is no network, disk, scene or real
## inference. Every scheduler transition receives an explicit clock value.

const ModelTask = preload("res://ai/model_task.gd")
const Scheduler = preload("res://ai/model_scheduler.gd")
const Loans = preload("res://farm/loan_state.gd")

const BASE: float = 1000.0

var checks: int = 0
var failures: Array[String] = []


class FakeBackend:
	var load_calls: int = 0
	var generate_calls: int = 0
	var unload_calls: int = 0
	var is_loaded: bool = false
	var load_ok: bool = true
	var responses: Array = []
	var generated_tasks: Array = []

	func load() -> bool:
		load_calls += 1
		is_loaded = load_ok
		return load_ok

	func generate(task: Dictionary) -> Variant:
		generate_calls += 1
		generated_tasks.append(task.duplicate(true))
		if responses.is_empty():
			return {"ok": true, "response": _default_response(task)}
		return responses.pop_front()

	func unload() -> void:
		unload_calls += 1
		is_loaded = false

	func loaded() -> bool:
		return is_loaded

	func _default_response(task: Dictionary) -> Variant:
		if str(task.type) == ModelTask.TYPE_INTENT:
			return {
				"intent": "greet", "confidence": 0.5, "reason": "",
				"state_version": str(task.state_version),
			}
		return "ok"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_disabled()
	_test_lazy_load_and_serial()
	_test_queue_full()
	_test_timeout()
	_test_cancel()
	_test_idle_unload()
	_test_resource_limits()
	_test_backend_failures()
	for failure: String in failures:
		push_error(failure)
	print("MODEL_SCHEDULER_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_disabled() -> void:
	var backend := FakeBackend.new()
	var scheduler := Scheduler.new(backend, "world-a", "state-v1", {"enabled": false})
	var task: Dictionary = _task("off-1")
	var submitted: Dictionary = scheduler.submit(task, BASE)
	_expect(not submitted.ok and submitted.reason == "disabled",
		"A disabled scheduler refuses a task immediately")
	var polled: Dictionary = scheduler.poll(BASE)
	_expect(not polled.ok and polled.reason == "disabled",
		"A disabled scheduler polls as disabled")
	_expect(backend.load_calls == 0 and backend.generate_calls == 0,
		"A disabled scheduler never loads or generates")
	_expect(Loans.quote(100, 604800, BASE).ok,
		"A pure world rule still runs while the model scheduler is disabled")
	var enabled: Dictionary = scheduler.set_enabled(true, BASE)
	_expect(enabled.ok and scheduler.enabled, "The scheduler can be enabled again")
	_expect(scheduler.submit(task, BASE).ok, "An enabled scheduler accepts the task")
	var finished: Dictionary = scheduler.poll(BASE)
	_expect(finished.ok and finished.status == "completed"
		and backend.load_calls == 1 and backend.generate_calls == 1,
		"Enabling restores lazy loading and generation")
	var off: Dictionary = scheduler.set_enabled(false, BASE + 1.0)
	_expect(off.ok and off.unloaded and not scheduler.status().loaded
		and backend.unload_calls == 1,
		"Disabling clears the queue and unloads a loaded backend")
	_expect(scheduler.submit(task, BASE + 1.0).reason == "disabled",
		"A post-disable request is refused")
	var queued_backend := FakeBackend.new()
	var queued := Scheduler.new(queued_backend, "world-a", "state-v1")
	queued.submit(_task("q-1"), BASE)
	queued.submit(_task("q-2"), BASE)
	var cleared: Dictionary = queued.set_enabled(false, BASE)
	_expect(cleared.cancelled == 2 and queued.pending() == 0
		and queued_backend.load_calls == 0,
		"Disabling clears and cancels every queued task without loading")


func _test_lazy_load_and_serial() -> void:
	var backend := FakeBackend.new()
	backend.responses = [{"ok": true, "pending": true}]
	var scheduler := Scheduler.new(backend, "world-a", "state-v1")
	var first: Dictionary = _task("s-1")
	var second: Dictionary = _task("s-2")
	var third: Dictionary = _task("s-3")
	_expect(scheduler.submit(first, BASE).ok, "The first task is queued")
	_expect(scheduler.submit(second, BASE).ok, "The second task is queued")
	_expect(scheduler.submit(third, BASE).ok, "The third task is queued")
	_expect(backend.load_calls == 0, "Submitting does not load the backend")
	var waiting: Dictionary = scheduler.poll(BASE)
	_expect(waiting.ok and waiting.status == "waiting"
		and backend.load_calls == 1 and backend.generate_calls == 1,
		"The first poll lazily loads once and starts one task")
	var still_waiting: Dictionary = scheduler.poll(BASE + 1.0)
	_expect(still_waiting.status == "waiting" and backend.generate_calls == 1,
		"A second poll does not run another task while one is in flight")
	scheduler.cancel(first.cancel_id, BASE + 1.0)
	var second_done: Dictionary = scheduler.poll(BASE + 1.0)
	_expect(second_done.ok and second_done.status == "completed"
		and second_done.task_id == "s-2" and backend.generate_calls == 2,
		"After the in-flight task is cancelled the next task runs")
	var third_done: Dictionary = scheduler.poll(BASE + 2.0)
	_expect(third_done.ok and third_done.task_id == "s-3"
		and backend.generate_calls == 3,
		"The third task runs after the second completes")
	_expect(backend.load_calls == 1,
		"The backend is loaded exactly once across three tasks")


func _test_queue_full() -> void:
	var backend := FakeBackend.new()
	var scheduler := Scheduler.new(backend, "world-a", "state-v1", {"queue_limit": 2})
	_expect(scheduler.submit(_task("q-1"), BASE).ok, "The first queued task is accepted")
	_expect(scheduler.submit(_task("q-2"), BASE).ok, "The second queued task is accepted")
	var full: Dictionary = scheduler.submit(_task("q-3"), BASE)
	_expect(not full.ok and full.reason == "queue_full" and scheduler.pending() == 2
		and backend.generate_calls == 0,
		"A task over the queue limit returns queue_full without loading")
	_expect(scheduler.poll(BASE).ok, "The first queued task runs")
	_expect(scheduler.submit(_task("q-3"), BASE).ok,
		"A freed queue slot accepts another task")
	_expect(scheduler.poll(BASE + 1.0).task_id == "q-2", "The second task runs next")
	_expect(scheduler.poll(BASE + 2.0).task_id == "q-3", "The third task runs last")


func _test_timeout() -> void:
	var backend := FakeBackend.new()
	backend.responses = [{"ok": true, "pending": true}]
	var scheduler := Scheduler.new(backend, "world-a", "state-v1")
	var first: Dictionary = _task("t-1", ModelTask.TYPE_DIALOGUE, BASE + 10.0)
	var second: Dictionary = _task("t-2", ModelTask.TYPE_DIALOGUE, BASE + 100.0)
	scheduler.submit(first, BASE)
	scheduler.submit(second, BASE)
	_expect(scheduler.poll(BASE).status == "waiting", "The first task starts")
	_expect(scheduler.poll(BASE + 9.0).status == "waiting"
		and backend.generate_calls == 1, "A live in-flight task keeps waiting")
	var timed_out: Dictionary = scheduler.poll(BASE + 10.0)
	_expect(not timed_out.ok and timed_out.status == "timeout"
		and timed_out.reason == "timeout" and timed_out.task_id == "t-1"
		and backend.generate_calls == 1,
		"An in-flight task past its deadline times out without another generate")
	var next_done: Dictionary = scheduler.poll(BASE + 10.0)
	_expect(next_done.ok and next_done.status == "completed"
		and next_done.task_id == "t-2" and backend.generate_calls == 2,
		"A timed-out task allows the next queued task to run")

	var queued_backend := FakeBackend.new()
	var queued := Scheduler.new(queued_backend, "world-a", "state-v1")
	queued.submit(_task("t-3", ModelTask.TYPE_DIALOGUE, BASE + 5.0), BASE)
	var expired: Dictionary = queued.poll(BASE + 6.0)
	_expect(not expired.ok and expired.reason == "expired"
		and queued_backend.generate_calls == 0,
		"A task that expires while queued is refused without generating")
	queued.submit(_task("t-4"), BASE + 6.0)
	_expect(queued.poll(BASE + 6.0).status == "completed"
		and queued_backend.generate_calls == 1,
		"An expired queued task does not block the next task")
	_expect(not queued.poll(-1.0).ok and queued.poll(-1.0).reason == "invalid_time",
		"An invalid poll clock is refused")


func _test_cancel() -> void:
	var backend := FakeBackend.new()
	backend.responses = [{"ok": true, "pending": true}]
	var scheduler := Scheduler.new(backend, "world-a", "state-v1")
	var first: Dictionary = _task("c-1")
	var second: Dictionary = _task("c-2")
	scheduler.submit(first, BASE)
	scheduler.submit(second, BASE)
	_expect(scheduler.poll(BASE).status == "waiting"
		and backend.generate_calls == 1, "The first task is in flight")
	var cancelled: Dictionary = scheduler.cancel(first.cancel_id, BASE + 1.0)
	_expect(cancelled.ok and cancelled.cancelled == 1
		and scheduler.is_cancelled(first.cancel_id)
		and scheduler.pending() == 1,
		"Cancelling the in-flight id clears it and leaves the queued task")
	_expect(backend.generate_calls == 1,
		"Cancelling does not itself start another generation")
	var second_done: Dictionary = scheduler.poll(BASE + 1.0)
	_expect(second_done.ok and second_done.task_id == "c-2"
		and backend.generate_calls == 2,
		"Only a later poll starts the next task")
	var third: Dictionary = _task("c-3")
	scheduler.submit(third, BASE + 2.0)
	var queued_cancel: Dictionary = scheduler.cancel(third.cancel_id, BASE + 2.0)
	_expect(queued_cancel.cancelled == 1 and scheduler.pending() == 0,
		"A queued task can be cancelled before it starts")
	_expect(scheduler.poll(BASE + 2.0).status == "idle"
		and backend.generate_calls == 2,
		"A cancelled queued task never generates")
	_expect(scheduler.cancel("", BASE + 3.0).reason == "invalid_cancel_id",
		"An empty cancellation id is refused")
	_expect(scheduler.cancel("unknown-cancel", BASE + 3.0).cancelled == 0,
		"An unknown cancellation id clears nothing")
	var bounded := Scheduler.new(FakeBackend.new(), "world-a", "state-v1",
		{"max_cancelled_ids": 2})
	bounded.cancel("cancel-a", BASE)
	bounded.cancel("cancel-b", BASE)
	bounded.cancel("cancel-c", BASE)
	_expect(not bounded.is_cancelled("cancel-a") and bounded.is_cancelled("cancel-b")
		and bounded.is_cancelled("cancel-c") and bounded.cancelled_ids().size() == 2,
		"The cancellation set is bounded by evicting the oldest id")


func _test_idle_unload() -> void:
	var backend := FakeBackend.new()
	var scheduler := Scheduler.new(backend, "world-a", "state-v1",
		{"idle_unload_seconds": 60.0})
	scheduler.submit(_task("i-1", ModelTask.TYPE_DIALOGUE, BASE + 1000.0), BASE)
	var done: Dictionary = scheduler.poll(BASE)
	_expect(done.status == "completed" and scheduler.status().loaded
		and backend.unload_calls == 0, "A finished task leaves the model loaded")
	_expect(scheduler.poll(BASE + 59.0).status == "idle"
		and scheduler.status().loaded and backend.unload_calls == 0,
		"A backend below the idle threshold stays loaded")
	var unloaded: Dictionary = scheduler.poll(BASE + 60.0)
	_expect(unloaded.ok and unloaded.status == "unloaded"
		and not scheduler.status().loaded and backend.unload_calls == 1,
		"Reaching the idle threshold unloads the backend")
	scheduler.submit(_task("i-2", ModelTask.TYPE_DIALOGUE, BASE + 1000.0), BASE + 60.0)
	var reloaded: Dictionary = scheduler.poll(BASE + 60.0)
	_expect(reloaded.status == "completed" and backend.load_calls == 2
		and backend.generate_calls == 2,
		"A new request after idle unload reloads lazily")
	_expect(scheduler.unload(BASE + 61.0).status == "unloaded"
		and backend.unload_calls == 2, "A manual idle unload succeeds")
	_expect(scheduler.unload(BASE + 62.0).status == "idle",
		"A manual unload with nothing loaded is idle")
	scheduler.submit(_task("i-3", ModelTask.TYPE_DIALOGUE, BASE + 1000.0), BASE + 62.0)
	_expect(scheduler.unload(BASE + 62.0).reason == "busy",
		"A manual unload with queued work is refused as busy")


func _test_resource_limits() -> void:
	var backend := FakeBackend.new()
	var scheduler := Scheduler.new(backend, "world-a", "state-v1")
	var task: Dictionary = _task("r-1")
	var hidden: Dictionary = task.duplicate(true)
	hidden.visible_context = {"secret": 1}
	_expect(scheduler.submit(hidden, BASE).reason == "unknown_context_key"
		and backend.generate_calls == 0,
		"The scheduler refuses an unknown visible-context field")
	var large: Dictionary = task.duplicate(true)
	large.visible_context = {"message": "a".repeat(8200)}
	_expect(scheduler.submit(large, BASE).reason == "context_too_large",
		"The scheduler refuses an oversized context")
	var bad_type: Dictionary = task.duplicate(true)
	bad_type.type = "other"
	_expect(scheduler.submit(bad_type, BASE).reason == "unknown_type",
		"The scheduler refuses an unknown task type")
	var bad_limit: Dictionary = task.duplicate(true)
	bad_limit.output_schema = {"max_tokens": 0}
	_expect(scheduler.submit(bad_limit, BASE).reason == "invalid_output_limit",
		"The scheduler refuses an out-of-range output cap")
	_expect(scheduler.submit(_task("r-2", ModelTask.TYPE_DIALOGUE,
		BASE + 100.0, {"world_id": "world-b"}), BASE).reason == "cross_world",
		"The scheduler refuses another world's task")
	_expect(scheduler.submit(_task("r-3", ModelTask.TYPE_DIALOGUE,
		BASE + 100.0, {"state_version": "state-v2"}), BASE).reason
		== "state_version_mismatch", "The scheduler refuses another state version")
	_expect(scheduler.submit(_task("r-4", ModelTask.TYPE_DIALOGUE, BASE + 5.0),
		BASE + 6.0).reason == "expired", "The scheduler refuses an expired task")
	scheduler.cancel("cancel-x", BASE)
	_expect(scheduler.submit(_task("r-5", ModelTask.TYPE_DIALOGUE,
		BASE + 100.0, {"cancel_id": "cancel-x"}), BASE).reason == "cancelled",
		"The scheduler refuses a task whose cancellation is already known")
	_expect(backend.generate_calls == 0,
		"Every refused task reaches the backend zero times")


func _test_backend_failures() -> void:
	var invalid := Scheduler.new(RefCounted.new(), "world-a", "state-v1")
	_expect(invalid.submit(_task("b-0"), BASE).reason == "invalid_backend"
		and invalid.poll(BASE).reason == "invalid_backend",
		"A backend without the interface is refused before any work")
	var backend := FakeBackend.new()
	backend.load_ok = false
	var scheduler := Scheduler.new(backend, "world-a", "state-v1")
	scheduler.submit(_task("b-1"), BASE)
	var failed_load: Dictionary = scheduler.poll(BASE)
	_expect(not failed_load.ok and failed_load.status == "load_failed"
		and backend.load_calls == 1 and backend.generate_calls == 0
		and backend.unload_calls == 1 and not scheduler.status().loaded,
		"A failed load marks the task failed and cleans up")
	backend.load_ok = true
	scheduler.submit(_task("b-1-retry"), BASE + 1.0)
	var recovered: Dictionary = scheduler.poll(BASE + 1.0)
	_expect(recovered.ok and recovered.status == "completed"
		and backend.load_calls == 2 and backend.generate_calls == 1,
		"A later task retries the load and runs")
	backend.responses = [{"ok": false, "reason": "boom"}]
	scheduler.submit(_task("b-2"), BASE + 2.0)
	var backend_error: Dictionary = scheduler.poll(BASE + 2.0)
	_expect(not backend_error.ok and backend_error.status == "backend_error"
		and backend_error.detail == "boom",
		"A backend generate error is reported")
	backend.responses = [42]
	scheduler.submit(_task("b-3"), BASE + 3.0)
	_expect(scheduler.poll(BASE + 3.0).status == "backend_error",
		"A non-dictionary generate result is a backend error")
	var status: Dictionary = scheduler.status()
	_expect(status.world_id == "world-a" and status.state_version == "state-v1"
		and not status.in_flight and status.queued == 0,
		"The status report describes the scheduler boundary")


func _task(id: String, type: String = ModelTask.TYPE_DIALOGUE,
		deadline: float = BASE + 100.0, overrides: Dictionary = {}) -> Dictionary:
	var fields: Dictionary = {
		"id": id,
		"type": type,
		"world_id": "world-a",
		"state_version": "state-v1",
		"visible_context": {"npc_id": "npc-lin", "message": "你好"},
		"deadline_utc": deadline,
	}
	for key: Variant in overrides:
		fields[key] = overrides[key]
	var result: Dictionary = ModelTask.create(fields, BASE)
	if not result.ok:
		failures.append("fixture task " + id + " was refused: " + str(result.reason))
		checks += 1
		return {}
	return result.task


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
