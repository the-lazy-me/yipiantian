extends SceneTree
## The room panel's "更换加入码" control as a view: it asks before doing anything,
## emits exactly one rotation intent, and afterwards shows whatever the game
## reports. Rotating disconnects members, so a stray click must never rotate.

const RoomPanel = preload("res://ui/room_panel.gd")

var checks: int = 0
var failures: Array[String] = []
var panel: RoomPanel
var events: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = RoomPanel.new()
	panel.name = "RoomPanel"
	root.add_child(panel)
	panel.rotate_requested.connect(func() -> void: events.append({"type": "rotate"}))
	await process_frame

	# Idle: there is no room to rotate yet, so the control must not be offered.
	panel.show_idle()
	_expect(not panel._rotate.visible,
		"An idle panel does not offer to rotate a room that does not exist")

	panel.show_room("FARMJ1.first", "FARMJ1.visitor-first")
	_expect(panel._rotate.visible and panel._rotate.text.contains("加入码"),
		"A started room offers a button to replace its codes")

	# Clicking asks first; nothing is emitted while the question is open.
	panel._rotate.pressed.emit()
	await process_frame
	_expect(panel._rotate_confirm.visible, "The rotate button opens a confirmation")
	_expect(events.is_empty(), "Opening the confirmation asks for no rotation yet")
	var confirm_text: String = panel._rotate_confirm.dialog_text
	_expect(confirm_text.contains("断开") and confirm_text.contains("失效"),
		"The confirmation says members will be disconnected and both codes stop working")

	# Cancelling changes nothing and leaves the codes in place.
	panel._rotate_confirm.get_cancel_button().pressed.emit()
	await process_frame
	_expect(events.is_empty(), "Cancelling the confirmation requests no rotation")
	_expect(not panel._rotate_confirm.visible, "Cancelling closes the confirmation")
	_expect(panel._room_code.text == "FARMJ1.first"
		and panel._visitor_code.text == "FARMJ1.visitor-first",
		"Cancelling leaves both codes exactly as they were")
	_expect(panel._rotate.text.is_empty() == false and not panel._rotate.disabled,
		"Cancelling leaves the rotate control usable")

	# Pressing Esc closes the confirmation, not the whole panel behind it.
	panel._rotate.pressed.emit()
	await process_frame
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	root.push_input(escape)
	await process_frame
	_expect(not panel._rotate_confirm.visible and panel.is_open(),
		"Esc dismisses the confirmation without closing the room panel")
	_expect(events.is_empty(), "Esc dismisses the confirmation without rotating")

	# Confirming requests exactly one rotation, and the panel reports progress.
	panel._rotate.pressed.emit()
	await process_frame
	panel._rotate_confirm.get_ok_button().pressed.emit()
	await process_frame
	_expect(events.size() == 1 and events[0].type == "rotate",
		"Confirming requests the rotation exactly once")
	_expect(not panel._rotate_confirm.visible, "Confirming closes the confirmation")
	panel.show_rotating()
	_expect(panel._rotate.disabled and panel._enter.disabled,
		"While rotating, the next rotation and entrance cannot be started")
	_expect(panel._room_code.text == "FARMJ1.first",
		"While rotating, the old member code stays visible")

	# Success replaces both codes, re-enables the controls and copies the member
	# code like a freshly opened room. Headless display servers have no
	# clipboard, so the panel's own "已复制" line is the observable here.
	panel.show_rotated("FARMJ1.second", "FARMJ1.visitor-second")
	_expect(panel._room_code.text == "FARMJ1.second",
		"Success shows the new member code")
	_expect(panel._visitor_code.text == "FARMJ1.visitor-second"
		and panel._visitor_block.visible,
		"Success shows the new visitor code")
	_expect(not panel._rotate.disabled and not panel._enter.disabled,
		"Success leaves the controls usable again")
	_expect(panel._status.text.contains("已更换") and panel._status.text.contains("已复制"),
		"Success says the codes were replaced and copied")

	# A rotated room may come back without a visitor code: the member code and
	# the entrance still work, and the panel says why the visitor one is absent.
	panel.show_rotated("FARMJ1.third", "")
	_expect(panel._room_code.text == "FARMJ1.third"
		and not panel._visitor_block.visible and panel._enter.visible,
		"A rotation without a visitor code still shows the member code and entrance")
	_expect(panel._status.text.contains("访客") and panel._status.text.contains("不可用"),
		"A missing visitor code is reported instead of hidden silently")

	# Failure keeps everything that was still in force: no code is blanked and
	# the authority's own reason is the message.
	panel.show_rotated("FARMJ1.third", "FARMJ1.visitor-third")
	panel.show_rotate_failure("房间进程还没有完全退出，加入码没有更换；请稍后重试。")
	_expect(panel._room_code.text == "FARMJ1.third"
		and panel._visitor_code.text == "FARMJ1.visitor-third",
		"A failed rotation keeps both old codes on screen")
	_expect(panel._status.text.contains("没有更换"),
		"A failed rotation shows the authority's reason")
	_expect(not panel._rotate.disabled and panel._enter.visible,
		"A failed rotation still lets the host retry or enter the room")

	# Leaving the panel dismisses a confirmation that was left open.
	panel._rotate.pressed.emit()
	await process_frame
	panel._close()
	await process_frame
	_expect(not panel._rotate_confirm.visible and not panel.is_open(),
		"Closing the panel also dismisses its confirmation")
	_finish()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("ROOM_PANEL_ROTATION_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
