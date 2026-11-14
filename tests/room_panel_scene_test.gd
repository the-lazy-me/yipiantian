extends SceneTree
## The room panel as a view: pasting a code, opening a room, showing the code to
## share, and leaving the panel. It decides nothing about the world, so a click
## here proves only which intent the game receives.

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
	panel.join_requested.connect(func(code: String) -> void:
		events.append({"type": "join", "code": code}))
	panel.host_requested.connect(func() -> void: events.append({"type": "host"}))
	panel.local_requested.connect(func() -> void: events.append({"type": "local"}))
	panel.closed.connect(func() -> void: events.append({"type": "closed"}))
	await process_frame

	panel.show_idle()
	_expect(panel.is_open(), "The panel opens on the loading screen")
	_expect(panel._status.text.contains("加入码"), "An idle panel explains what it wants")

	# Joining needs a code: an empty box stays local instead of dialing.
	panel._code.text = "   "
	_click(panel, "Join")
	await process_frame
	_expect(events.is_empty(), "An empty code is refused before anything is requested")
	_expect(panel._status.text.contains("先粘贴"), "An empty code says what is missing")

	panel._code.text = "  FARMJ1.abc  "
	_click(panel, "Join")
	await process_frame
	_expect(events.size() == 1 and events[0].type == "join"
		and events[0].code == "FARMJ1.abc", "Pasting a code asks to join that world, trimmed")

	panel.show_joining()
	_expect(panel._join.disabled and panel._host.disabled,
		"While joining, no second request can be started")
	_expect(not panel._code.editable, "The code cannot be edited mid-join")

	panel.show_room("FARMJ1.room")
	_expect(panel._room_row.visible and panel._room_code.text == "FARMJ1.room",
		"A started room shows the code the host can share")
	_expect(panel._enter.visible, "The host can enter the room they just opened")
	_click(panel, "Copy")
	await process_frame
	_expect(panel._status.text.contains("已复制"), "Copying says so on the panel")
	_click(panel, "Enter")
	await process_frame
	_expect(events.size() == 2 and events[1].type == "join"
		and events[1].code == "FARMJ1.room", "Entering the room joins it with its own code")

	panel.show_failure("连不上这个地址")
	_expect(panel._local.visible, "A failure offers going back to a local farm")
	_expect(panel._status.text.contains("连不上"), "A failure is shown as the reason")
	_click(panel, "Local")
	await process_frame
	_expect(events.size() == 3 and events[2].type == "local",
		"Going back to a local farm is a separate decision")

	panel.show_idle()
	_click(panel, "Host")
	await process_frame
	_expect(events.size() == 4 and events[3].type == "host",
		"Opening a room is requested and nothing else")
	_click(panel, "Close")
	await process_frame
	_expect(not panel.is_open(), "Closing hides the panel")
	_expect(events.size() == 5 and events[4].type == "closed", "Closing is reported to the game")
	_finish()


func _click(node: Node, button_name: String) -> void:
	var button: Button = node.find_child(button_name, true, false) as Button
	_expect(button != null, "The '%s' button exists" % button_name)
	if button != null:
		button.pressed.emit()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("ROOM_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
