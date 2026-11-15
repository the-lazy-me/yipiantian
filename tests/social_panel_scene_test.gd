extends SceneTree
## The neighbours panel as a view: given one authoritative social document it
## renders the sections a player needs and turns clicks into action intents.
## No network and no authority are involved, which is the point: the panel must
## not decide rules, so none of them can be exercised from here.

const SocialPanel = preload("res://ui/social_panel.gd")

const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"
const CAROL: String = "player_00000000000000000000000000000003"
const DAVE: String = "player_00000000000000000000000000000004"

var checks: int = 0
var failures: Array[String] = []
var panel: SocialPanel
var sent: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = SocialPanel.new()
	panel.name = "Panel"
	root.add_child(panel)
	panel.action_requested.connect(func(action: String, args: Dictionary) -> void:
		sent.append({"action": action, "args": args}))
	await process_frame

	panel.present({}, [])
	_expect(panel._online.get_child(0).text.contains("还没有收到"),
		"An unanswered view says so instead of showing an empty neighbourhood")

	panel.present(_view(), [{"name": "阿青", "player_id": ALICE, "role": "member"},
		{"name": "", "player_id": "", "role": "member"}])
	_expect(_has_text(panel._online, "阿青（成员）"), "Online members are listed with their role")
	_expect(_has_text(panel._online, "一位匿名旅人"), "An anonymous member is not given a made-up name")
	_expect(_has_text(panel._invites, "阿禾 想和你成为邻里"), "An incoming invitation names the sender")
	_expect(_has_text(panel._invites, "已邀请 老周"), "An outgoing invitation shows as waiting")
	_expect(_has_text(panel._contacts, "小满"), "Contacts are listed")
	_expect(_has_text(panel._messages, "· 小满：门口放了两把小葱。"),
		"An unread message is marked and shows its sender")
	_expect(_has_text(panel._grants, "给小满：harvest · 整座农场 · 不过期"),
		"An outgoing grant shows its scope and that it does not expire")

	# Accepting an invitation emits exactly the intent; the authority decides.
	_click(panel._invites, "接受")
	await process_frame
	_expect(sent.size() == 1 and sent[0].action == "accept" and sent[0].args.player_id == CAROL,
		"Accepting an invitation asks the authority for that person")
	_click(panel._contacts, "移除")
	await process_frame
	_expect(sent.size() == 2 and sent[1].action == "remove" and sent[1].args.player_id == BOB,
		"Removing a contact names the contact")
	_click(panel._grants, "撤销")
	await process_frame
	_expect(sent.size() == 3 and sent[2].action == "revoke" and sent[2].args.id == "grant_1",
		"Revoking a grant names the grant")
	_click(panel._messages, "已读")
	await process_frame
	_expect(sent.size() == 4 and sent[3].action == "read" and sent[3].args.id == "msg_1",
		"Marking a message read names the message")

	# Sending: blank text is refused locally, a real one carries the target.
	panel._compose.text = "   "
	_click(panel, "Send")
	await process_frame
	_expect(sent.size() == 4 and panel._status.text.contains("先写一句"),
		"A blank message is refused before it becomes a request")
	panel._compose.text = "晚饭后过来喝茶。"
	panel._target.select(1)
	_click(panel, "Send")
	await process_frame
	_expect(sent.size() == 5 and sent[4].action == "send"
		and sent[4].args.text == "晚饭后过来喝茶。" and sent[4].args.to == BOB,
		"A message is sent to the chosen contact")
	_expect(panel._compose.text.is_empty(), "Sending clears the composer")

	# Gifts come from the player's own bag: only owned produce is offered, and a
	# gift is one deliberate click naming a neighbour and a crop.
	panel.present(_view(), [{"name": "阿青", "player_id": ALICE, "role": "member"}], {})
	_expect(panel._gift_button.disabled and panel._gift_hint.text.contains("没有收成"),
		"An empty bag offers nothing to give")
	panel.present(_view(), [{"name": "阿青", "player_id": ALICE, "role": "member"}],
		{"greens": 2, "radish": 0})
	_expect(not panel._gift_button.disabled, "Owned produce enables the gift button")
	_expect(panel._gift_crop.item_count == 1 and panel._gift_crop.get_item_text(0) == "青菜 ×2",
		"Only produce with a balance is offered, with its count (got %d)" % panel._gift_crop.item_count)
	_click(panel, "Gift")
	await process_frame
	_expect(sent.size() == 6 and sent[5].action == "gift"
		and sent[5].args.crop_id == "greens" and sent[5].args.amount == 1
		and sent[5].args.player_id == BOB, "A gift names the contact, the crop and one unit")

	# Theft is a standing, not an action: the box mirrors the authority and a
	# change states exactly one intent.
	panel.present(_view(), [], {}, false)
	_expect(not panel._theft_box.button_pressed, "Theft is off until the authority says otherwise")
	var before: int = sent.size()
	panel._theft_box.button_pressed = true
	await process_frame
	_expect(sent.size() == before + 1 and sent[before].action == "set_theft"
		and sent[before].args.enabled == true, "Turning theft on states one intent")
	panel.present(_view(), [], {}, true)
	await process_frame
	_expect(panel._theft_box.button_pressed and sent.size() == before + 1,
		"A view that already says theft is on does not send another intent")

	# A host can get its join code back after the room panel is gone.
	panel.show_room_code("")
	_expect(not panel._room_row.visible, "A member has no room code to show")
	panel.show_room_code("FARMJ1.room")
	_expect(panel._room_row.visible and panel._room_code.text == "FARMJ1.room",
		"A host sees the room's join code in the neighbours panel")
	_click(panel, "CopyRoom")
	await process_frame
	_expect(panel._status.text.contains("已复制"), "Copying the room code says so")

	panel.show_status("对方已经把你屏蔽了")
	_expect(panel._status.text.contains("屏蔽"), "An authority refusal can be surfaced on the panel")

	# Keyboard ownership, focus-following lists, preserved choices and composer
	# Enter. The opener stands in for the HUD button main.gd uses.
	var opener := Button.new()
	opener.text = "opener"
	root.add_child(opener)
	opener.grab_focus()
	var roster: Array = [{"name": "阿青", "player_id": ALICE, "role": "member"}]
	panel.present(_view(), roster, {"greens": 2})
	panel.show()
	await process_frame
	var focus_owner: Control = root.gui_get_focus_owner()
	_expect(focus_owner != null and panel.is_ancestor_of(focus_owner),
		"Opening the neighbours panel captures keyboard focus inside it")
	var scroll: ScrollContainer = panel.find_child("Scroll", true, false) as ScrollContainer
	_expect(scroll != null and scroll.follow_focus,
		"The neighbours list scrolls to follow keyboard focus")
	panel._target.select(1)
	panel.present(_view(), roster, {"greens": 2})
	_expect(panel._target.selected >= 0
		and str(panel._target.get_item_metadata(panel._target.selected)) == BOB,
		"A refresh keeps the private recipient chosen by player id")
	panel.show_status("对方已经把你屏蔽了")
	panel.present(_view(), roster, {"greens": 2})
	_expect(panel._status.text.contains("屏蔽"), "A neighbours refresh keeps the last refusal message")
	var remove: Button = panel._contacts.find_child("移除", true, false) as Button
	remove.grab_focus()
	panel.present(_view(), roster, {"greens": 2})
	var restored: Control = root.gui_get_focus_owner()
	_expect(restored != null and str(restored.get_meta("focus_key", "")) == "remove|" + BOB,
		"Refreshing the contacts restores focus to the same contact's button")
	var send: Button = panel.find_child("Send", true, false) as Button
	send.grab_focus()
	var tab_event := InputEventKey.new()
	tab_event.keycode = KEY_TAB
	tab_event.pressed = true
	root.push_input(tab_event)
	await process_frame
	_expect(root.gui_get_focus_owner() == panel.find_child("Refresh", true, false),
		"Real Tab input wraps from the last neighbours control back to the first")
	tab_event.pressed = false
	root.push_input(tab_event)
	var before_enter: int = sent.size()
	panel._compose.text = "晚饭后过来喝茶。"
	panel._target.select(0)
	panel._compose.text_submitted.emit(panel._compose.text)
	await process_frame
	_expect(sent.size() == before_enter + 1 and sent.back().action == "send"
		and sent.back().args.text == "晚饭后过来喝茶。",
		"Enter in the message field sends the same intent as the button")
	_expect(panel._compose.get_theme_stylebox("normal") != null
		and panel._compose.get_theme_stylebox("read_only") != null
		and panel._compose.get_theme_stylebox("focus") != null,
		"Line edits inherit readable shared styles")
	_expect(panel._theft_box.get_theme_icon("checked") != null
		and panel._theft_box.get_theme_icon("unchecked") != null,
		"Check boxes inherit readable shared icons")
	var close: Button = panel.find_child("Close", true, false) as Button
	close.pressed.emit()
	await process_frame
	_expect(root.gui_get_focus_owner() == opener,
		"Closing returns keyboard focus to the control that opened the panel")
	_finish()


func _view() -> Dictionary:
	return {
		"player_id": ALICE, "name": "阿青",
		"contacts": [{"player_id": BOB, "name": "小满", "since": 1800000000.0}],
		"pending": [
			{"player_id": CAROL, "name": "阿禾", "at": 1800000000.0, "direction": "in"},
			{"player_id": DAVE, "name": "老周", "at": 1800000000.0, "direction": "out"},
		],
		"blocks": [],
		"grants": [{"id": "grant_1", "from": ALICE, "from_name": "阿青", "to": BOB,
			"to_name": "小满", "kinds": ["harvest"], "fields": [], "created": 1800000000.0,
			"expires_at": 0.0, "direction": "out"}],
		"inbox": [{"id": "msg_1", "from": BOB, "from_name": "小满", "to": "", "to_name": "",
			"text": "门口放了两把小葱。", "at": 1800000000.0, "read": false}],
	}


func _has_text(node: Node, fragment: String) -> bool:
	for child: Node in node.get_children():
		if child is Label and (child as Label).text.contains(fragment):
			return true
		if _has_text(child, fragment):
			return true
	return false


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
	print("SOCIAL_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
