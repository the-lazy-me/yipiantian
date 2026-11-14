extends RefCounted
## Adapter for the macos_desktop GDExtension.
##
## The library is built from native/macos_desktop and installed under
## res://native/macos_desktop/ by that build script. A fresh checkout can open
## the project before the native build exists, so every call reports
## unavailable instead of failing at load time.

const CLASS_NAME: String = "MacDesktop"


static func available() -> bool:
	return OS.get_name() == "macOS" and ClassDB.class_exists(CLASS_NAME)


var _native: Object


func _init() -> void:
	if available():
		_native = ClassDB.instantiate(CLASS_NAME)


func is_ready() -> bool:
	return _native != null


func probe() -> Dictionary:
	if _native == null: return {}
	return _native.probe()


func attach(window_handle: int) -> bool:
	return _native != null and bool(_native.attach(window_handle))


func reassert(window_handle: int) -> bool:
	return _native != null and bool(_native.reassert(window_handle))


func detach(window_handle: int) -> bool:
	return _native != null and bool(_native.detach(window_handle))


func layer(window_handle: int) -> int:
	return int(_native.layer(window_handle)) if _native != null else -2147483648


func occlusion_visible(window_handle: int) -> bool:
	return _native != null and bool(_native.occlusion_visible(window_handle))


## Menu-bar commands are polled once per frame; 0 means nothing pending.
func show_status_item() -> void:
	if _native != null and _native.has_method("show_status_item"):
		_native.show_status_item()


func hide_status_item() -> void:
	if _native != null and _native.has_method("hide_status_item"):
		_native.hide_status_item()


func take_command() -> int:
	if _native == null or not _native.has_method("take_command"): return 0
	return int(_native.take_command())


## Bit 0: user session active; bit 1: displays awake. Both default to 1.
func system_state() -> int:
	if _native == null or not _native.has_method("system_state"): return 3
	return int(_native.system_state())


## Removes workspace observers and the status item; safe to call twice.
func shutdown() -> void:
	if _native != null and _native.has_method("shutdown"):
		_native.shutdown()
