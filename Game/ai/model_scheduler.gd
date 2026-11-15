extends RefCounted
## M9-03 single-queue model scheduler. Deterministic, poll-driven and clock
## injected: every state transition takes `now_utc`, so tests and future
## integrations control time without reading an engine clock.
##
## Backend interface (duck-typed, injected):
##   load() -> bool | Dictionary | void   # void counts as success
##   generate(task) -> Dictionary
##   unload() -> void
##   loaded() -> bool
##
## Optional hooks, used only when present:
##   poll() -> Dictionary                # advance an asynchronous generation
##   abort() -> void                     # stop it on cancel/timeout/disable
##
## `generate` and `poll` return:
##   {ok: true, response: <JSON string|Dictionary>}   # finished now
##   {ok: true, pending: true}                        # still running
##   {ok: false, reason: "...", detail: "..."}        # backend error
##
## A model/process backend is optional and injected. The scheduler lazily calls
## `load` when the first task actually starts, runs at most one task at a time,
## enforces the queue limit, task deadline, cancellation and idle unload, and
## discards late results through the protocol's cancellation set. It never
## mutates world state; a finished response is only a protocol suggestion.

const Task = preload("res://ai/model_task.gd")

const DEFAULT_QUEUE_LIMIT: int = 8
const DEFAULT_IDLE_UNLOAD_SECONDS: float = 60.0
const MAX_QUEUE_LIMIT: int = 64
const DEFAULT_MAX_CANCELLED_IDS: int = 256
const MAX_CANCELLED_IDS: int = 1024

var backend: Object = null
var world_id: String = ""
var state_version: String = ""
var enabled: bool = true
var queue_limit: int = DEFAULT_QUEUE_LIMIT
var idle_unload_seconds: float = DEFAULT_IDLE_UNLOAD_SECONDS
var max_cancelled_ids: int = DEFAULT_MAX_CANCELLED_IDS

var _queue: Array[Dictionary] = []
var _current: Dictionary = {}
var _in_flight: bool = false
var _last_activity_utc: float = 0.0
var _cancelled_order: Array[String] = []
var _cancelled: Dictionary = {}


func _init(backend_object: Object, world: String, version: String,
		options: Dictionary = {}) -> void:
	backend = backend_object
	world_id = str(world)
	state_version = str(version)
	var raw_enabled: Variant = options.get("enabled", true)
	if raw_enabled is bool:
		enabled = bool(raw_enabled)
	var raw_queue: Variant = options.get("queue_limit", DEFAULT_QUEUE_LIMIT)
	if raw_queue is int and int(raw_queue) >= 1 and int(raw_queue) <= MAX_QUEUE_LIMIT:
		queue_limit = int(raw_queue)
	var raw_idle: Variant = options.get("idle_unload_seconds", DEFAULT_IDLE_UNLOAD_SECONDS)
	if (raw_idle is int or raw_idle is float) and is_finite(float(raw_idle)) \
			and float(raw_idle) >= 0.0:
		idle_unload_seconds = float(raw_idle)
	var raw_cancelled: Variant = options.get(
		"max_cancelled_ids", DEFAULT_MAX_CANCELLED_IDS)
	if raw_cancelled is int and int(raw_cancelled) >= 1 \
			and int(raw_cancelled) <= MAX_CANCELLED_IDS:
		max_cancelled_ids = int(raw_cancelled)


## Queues a task after the protocol boundary check. The queued copy is owned by
## the scheduler, so a caller cannot mutate a running task.
func submit(task: Variant, now_utc: float) -> Dictionary:
	if not _backend_ok():
		return _error("invalid_backend")
	if not enabled:
		return _error("disabled")
	if not Task.valid_time(now_utc):
		return _error("invalid_time")
	var checked: Dictionary = Task.validate(
		task, world_id, state_version, now_utc, _cancelled)
	if not checked.ok:
		return _error(str(checked.reason))
	if _queue.size() >= queue_limit:
		return _error("queue_full")
	var copy: Dictionary = (task as Dictionary).duplicate(true)
	_queue.append(copy)
	return {
		"ok": true, "status": "queued", "reason": "",
		"task_id": str(copy.id), "queued": _queue.size(),
	}


## Advances at most one transition: idle unload, timeout, waiting, expiry,
## load failure, backend error, rejected response or completed suggestion.
func poll(now_utc: float) -> Dictionary:
	if not _backend_ok():
		return _error("invalid_backend")
	if not enabled:
		return _error("disabled")
	if not Task.valid_time(now_utc):
		return _error("invalid_time")
	if _in_flight:
		if now_utc >= float(_current.deadline_utc):
			var timed_out: String = str(_current.id)
			_abort_backend()
			_in_flight = false
			_current = {}
			_last_activity_utc = now_utc
			return {
				"ok": false, "status": "timeout", "reason": "timeout",
				"task_id": timed_out,
			}
		var advanced: Variant = _poll_backend()
		if advanced is Dictionary:
			return _settle(_current, advanced, now_utc)
		return {
			"ok": true, "status": "waiting", "reason": "",
			"task_id": str(_current.id),
		}
	if _queue.is_empty():
		return _idle(now_utc)
	var task: Dictionary = _queue.pop_front()
	if Task.expired(task, now_utc):
		return {
			"ok": false, "status": "expired", "reason": "expired",
			"task_id": str(task.id),
		}
	if not _loaded():
		var loaded: Dictionary = _load_backend()
		if not loaded.ok:
			backend.unload()
			return {
				"ok": false, "status": "load_failed", "reason": "load_failed",
				"task_id": str(task.id), "detail": str(loaded.reason),
				"backend_detail": str(loaded.detail),
			}
	_last_activity_utc = now_utc
	var generated: Variant = backend.generate(task.duplicate(true))
	if not generated is Dictionary:
		return {
			"ok": false, "status": "backend_error", "reason": "backend_error",
			"task_id": str(task.id),
		}
	return _settle(task, generated, now_utc)


## Cancels one id: removes matching queued tasks and stops the in-flight task
## from being polled again. A late result for this id is refused by the
## protocol's cancellation set. Returns how many tasks were cleared.
func cancel(cancel_id: Variant, now_utc: float) -> Dictionary:
	if not Task.valid_cancel_id(cancel_id):
		return _error("invalid_cancel_id")
	if not Task.valid_time(now_utc):
		return _error("invalid_time")
	var id: String = str(cancel_id)
	_record_cancel(id)
	var cleared: int = 0
	var kept: Array[Dictionary] = []
	for task: Dictionary in _queue:
		if str(task.get("cancel_id", "")) == id:
			cleared += 1
		else:
			kept.append(task)
	_queue = kept
	if _in_flight and str(_current.get("cancel_id", "")) == id:
		_abort_backend()
		cleared += 1
		_in_flight = false
		_current = {}
		_last_activity_utc = now_utc
	return {"ok": true, "status": "cancelled", "reason": "", "cancelled": cleared}


## Fully off: every request returns `disabled`, the queue is cleared, in-flight
## state is dropped and a loaded backend is unloaded. World rules never consult
## this object, so they keep running.
func set_enabled(value: bool, now_utc: float) -> Dictionary:
	if value:
		enabled = true
		return {"ok": true, "status": "enabled", "reason": "", "cancelled": 0,
			"unloaded": false}
	enabled = false
	var cleared: int = 0
	for task: Dictionary in _queue:
		var id: String = str(task.get("cancel_id", ""))
		if not id.is_empty():
			_record_cancel(id)
		cleared += 1
	_queue.clear()
	if _in_flight:
		var current_id: String = str(_current.get("cancel_id", ""))
		if not current_id.is_empty():
			_record_cancel(current_id)
		_abort_backend()
		cleared += 1
		_in_flight = false
		_current = {}
	var unloaded: bool = false
	if _loaded():
		backend.unload()
		unloaded = true
	_last_activity_utc = now_utc
	return {"ok": true, "status": "disabled", "reason": "disabled",
		"cancelled": cleared, "unloaded": unloaded}


## Manual unload only when nothing is queued or running.
func unload(now_utc: float) -> Dictionary:
	if not _backend_ok():
		return _error("invalid_backend")
	if not Task.valid_time(now_utc):
		return _error("invalid_time")
	if _in_flight or not _queue.is_empty():
		return _error("busy")
	var was_loaded: bool = _loaded()
	if was_loaded:
		backend.unload()
		_last_activity_utc = now_utc
	return {
		"ok": true, "status": "unloaded" if was_loaded else "idle", "reason": "",
	}


func is_cancelled(cancel_id: Variant) -> bool:
	if not cancel_id is String:
		return false
	return _cancelled.has(str(cancel_id))


func cancelled_ids() -> Array:
	return _cancelled_order.duplicate()


func pending() -> int:
	return _queue.size() + (1 if _in_flight else 0)


func status() -> Dictionary:
	return {
		"enabled": enabled,
		"loaded": _loaded(),
		"in_flight": _in_flight,
		"queued": _queue.size(),
		"pending": pending(),
		"cancelled": _cancelled.size(),
		"world_id": world_id,
		"state_version": state_version,
		"last_activity_utc": _last_activity_utc,
	}


func _idle(now_utc: float) -> Dictionary:
	if not _loaded():
		return {"ok": true, "status": "idle", "reason": ""}
	if now_utc - _last_activity_utc < idle_unload_seconds:
		return {"ok": true, "status": "idle", "reason": ""}
	backend.unload()
	return {"ok": true, "status": "unloaded", "reason": ""}


func _backend_ok() -> bool:
	return backend != null and is_instance_valid(backend) \
		and backend.has_method("load") and backend.has_method("generate") \
		and backend.has_method("unload") and backend.has_method("loaded")


func _loaded() -> bool:
	if not _backend_ok():
		return false
	var value: Variant = backend.loaded()
	if value is bool:
		return bool(value)
	if value is Dictionary:
		return bool(value.get("ok", false))
	return false


func _load_backend() -> Dictionary:
	var value: Variant = backend.load()
	if value is bool:
		return {"ok": bool(value), "reason": "" if bool(value) else "load_failed",
			"detail": ""}
	if value is Dictionary:
		return {
			"ok": bool(value.get("ok", false)),
			"reason": str(value.get("reason", "")),
			"detail": str(value.get("detail", "")),
		}
	return {"ok": true, "reason": "", "detail": ""}


## Resolves one backend result, shared by a synchronous `generate` and an
## asynchronous `poll`. Only the protocol's `accept` may turn text into a
## suggestion; nothing here touches world state.
func _settle(task: Dictionary, result: Dictionary, now_utc: float) -> Dictionary:
	if bool(result.get("pending", false)):
		_in_flight = true
		_current = task
		return {
			"ok": true, "status": "waiting", "reason": "",
			"task_id": str(task.id),
		}
	_in_flight = false
	_current = {}
	_last_activity_utc = now_utc
	if not bool(result.get("ok", false)):
		return {
			"ok": false, "status": "backend_error", "reason": "backend_error",
			"task_id": str(task.id), "detail": str(result.get("reason", "")),
			"backend_detail": str(result.get("detail", "")),
		}
	var accepted: Dictionary = Task.accept(
		task, world_id, state_version, result.get("response"), now_utc, _cancelled)
	return {
		"ok": bool(accepted.ok),
		"status": "completed" if bool(accepted.ok) else "rejected",
		"reason": str(accepted.reason),
		"task_id": str(task.id),
		"accepted": bool(accepted.accepted),
		"suggestion": accepted.suggestion,
	}


## Optional asynchronous hook: absent on simple synchronous fakes, present on
## process/thread backends.
func _poll_backend() -> Variant:
	if not _backend_ok() or not backend.has_method("poll"):
		return null
	var value: Variant = backend.poll()
	if not value is Dictionary:
		return {"ok": false, "reason": "backend_error"}
	return value


func _abort_backend() -> void:
	if _backend_ok() and backend.has_method("abort"):
		backend.abort()


func _record_cancel(cancel_id: String) -> void:
	if _cancelled.has(cancel_id):
		return
	_cancelled[cancel_id] = true
	_cancelled_order.append(cancel_id)
	while _cancelled_order.size() > max_cancelled_ids:
		var oldest: String = _cancelled_order.pop_front()
		_cancelled.erase(oldest)


func _error(reason: String) -> Dictionary:
	return {
		"ok": false, "status": reason, "reason": reason,
		"accepted": false, "suggestion": {}, "task_id": "",
	}
