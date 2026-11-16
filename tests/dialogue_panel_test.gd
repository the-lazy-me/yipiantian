extends SceneTree
## 对话面板作为视图：它只根据权威 `dialogues` 视图决定显示什么，并把七类固定
## 话语的点按变成一次 `say` 意图；冷却、日上限、邀约门限与拒绝原因都由权威决定。
##
## 没有网络：视图直接构造，面板在测试里通过一个假远程对象转发请求与答复。
## 面板类测试预加载共享主题字体，属 scene_tests 组。

const DialoguePanel = preload("res://ui/dialogue_panel.gd")
const NpcDialogue = preload("res://npc/npc_dialogue.gd")

const LIN: String = "npc_lin_shen"
const XU: String = "npc_xu_bo"
const ZHOU: String = "npc_a_zhou"
const PLAYER: String = "player_00000000000000000000000000000001"
const ORDER: Array[String] = [ZHOU, XU, LIN]


class FakeRemote extends RefCounted:
	signal dialogue_result(payload: Dictionary)

	var calls: Array = []

	func request_dialogue(request_id: String, action: String,
			args: Dictionary = {}) -> bool:
		calls.append({
			"request_id": request_id, "action": action,
			"args": args.duplicate(true),
		})
		return true


var panel: DialoguePanel
var fake: FakeRemote
var closes: int = 0
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = DialoguePanel.new()
	panel.name = "DialoguePanel"
	root.add_child(panel)
	fake = FakeRemote.new()
	fake.dialogue_result.connect(panel.apply_result)
	panel.dialogue_intent.connect(_forward_intent)
	panel.refresh_requested.connect(_request_refresh)
	panel.closed.connect(func() -> void: closes += 1)
	await process_frame
	_expect(not panel.is_open(), "The panel starts hidden until the player opens it")

	# A hidden panel must not consume Esc or steal focus from the HUD button.
	var opener := Button.new()
	opener.text = "opener"
	root.add_child(opener)
	opener.grab_focus()
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(not panel.is_open() and closes == 0,
		"A hidden panel ignores Esc instead of opening or closing itself")
	_expect(root.gui_get_focus_owner() == opener,
		"A hidden panel does not take focus from the HUD button")
	esc.pressed = false
	root.push_input(esc)
	await process_frame

	# An empty view is not an empty world: the panel says the world is not open
	# and renders no row and no say button.
	panel.open_panel({})
	_expect(panel.is_open(), "Opening the panel shows it")
	_expect(_status_line() == "世界尚未打开",
		"An empty view says the world is not open")
	_expect(not _list("DialogueList").visible and _list("DialogueList").get_child_count() == 0,
		"An empty view disables the resident list")
	_expect(not _action_section().visible,
		"An empty view hides the say buttons")
	_expect(_target().disabled, "An empty view disables the target picker")

	# The three authoritative unavailable reasons get distinct copy.
	panel.open_panel(_unavailable("disabled"))
	_expect(_status_line() == "居民对话尚未启用",
		"A disabled authority says dialogue is disabled")
	panel.open_panel(_unavailable("not_a_member"))
	_expect(_status_line() == "尚未加入这个世界",
		"A non-member view says the player has not joined")
	panel.open_panel(_unavailable("not_open"))
	_expect(_status_line() == "世界尚未打开",
		"A closed world says it is not open")

	# The authority's array order is rendered as-is: the fixture is deliberately
	# not in NpcRoster.IDS order and the panel must not sort it.
	panel.open_panel(_view(true))
	_expect(panel.is_open() and _list("DialogueList").visible,
		"An available view shows the resident list")
	_expect(panel.residents.size() == 3, "All authoritative residents are kept")
	_expect(_ids(panel.residents) == ORDER,
		"Resident rows keep the authority array order instead of sorting locally")
	var lin_text: String = _label_text("Dialogue_" + LIN)
	_expect(lin_text.contains("林婶") and lin_text.contains(LIN)
		and lin_text.contains("最近对话 未记录")
		and lin_text.contains("今日剩余 3 / 5")
		and lin_text.contains("可以对话"),
		"A resident row shows the id, last dialogue time, remaining points and cooldown")
	var zhou_text: String = _label_text("Dialogue_" + ZHOU)
	_expect(zhou_text.contains("UTC 1800052812")
		and zhou_text.contains("冷却中，还需约 120 秒"),
		"A cooled-down row shows the last time and the authoritative remaining seconds")

	# Seven fixed options whose labels come from the same category list as the
	# rule module; no button is invented or missing.
	_expect(_say_button_count() == NpcDialogue.CATEGORIES.size(),
		"The panel offers exactly the seven fixed categories")
	for category: String in NpcDialogue.CATEGORIES:
		var button: Button = _say_button(category)
		_expect(button != null and button.text == str(DialoguePanel.CATEGORY_LABELS[category]),
			"The %s option uses its fixed Chinese label" % category)
	_expect(_say_button("greet").text == "问候" and _say_button("ask_work").text == "问农事"
		and _say_button("ask_market").text == "问行情"
		and _say_button("apologize").text == "道歉"
		and _say_button("thank").text == "道谢"
		and _say_button("invite").text == "邀约"
		and _say_button("farewell").text == "告别",
		"The category labels match the rule module's seven categories")

	# The picker defaults to the first authoritative row; its earlier selection is
	# kept across a replacement when that resident is still present.
	_expect(_target().item_count == 3 and panel.selected_npc_id == ZHOU,
		"The picker defaults to the first authoritative resident")
	select_target(1)
	_expect(panel.selected_npc_id == XU, "Selecting a target only names the request object")
	var keep: int = fake.calls.size()
	panel.open_panel(_view(true))
	_expect(panel.selected_npc_id == XU,
		"A replacement keeps the selected resident when it is still present")

	# A ready row enables every say button; a cooled row and an exhausted day
	# disable them and say why, instead of failing silently.
	select_target(0)
	_expect(_say_button("greet").disabled,
		"A cooled-down resident cannot be talked to")
	_expect(_hint().contains("还需要等 120 秒"),
		"A cooled-down row states the remaining seconds")
	select_target(1)
	_expect(not _say_button("greet").disabled and _hint().is_empty(),
		"A ready resident enables the say buttons")
	panel.open_panel(_view_with_daily(5, 5, 1, 0.0))
	_expect(_say_button("greet").disabled and _hint().contains("今日对话点数已用完"),
		"An exhausted daily allowance disables the buttons and says why")
	panel.open_panel(_view_with_daily(0, 5, 1, 0.0))
	_expect(not _say_button("greet").disabled,
		"A refreshed UTC day restores the buttons from the authority's own count")

	# One press emits exactly one intent: the category, the selected resident and a
	# command id, never an actor, relation, time or visible fact.
	panel.open_panel(_view(true))
	select_target(1)
	var before: int = fake.calls.size()
	_say_button("greet").pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "say",
		"One press emits exactly one say intent")
	var args: Dictionary = fake.calls.back().args
	_expect(fake.calls.back().request_id == args.get("command_id")
		and not str(args.get("command_id", "")).is_empty(),
		"The request id doubles as the dialogue command id")
	_expect(args.get("npc_id") == XU and args.get("category") == "greet",
		"The intent names the selected resident and the fixed category")
	_expect(not args.has("actor") and not args.has("viewer")
		and not args.has("visible") and not args.has("now_utc"),
		"The panel sends no actor, viewer, visible fact or time")
	_expect(panel.view == _view(true),
		"Pressing a say button changes nothing on the panel before the reply")

	# Each of the seven categories forwards its own category, one intent per press.
	for category: String in NpcDialogue.CATEGORIES:
		before = fake.calls.size()
		_say_button(category).pressed.emit()
		await process_frame
		_expect(fake.calls.size() == before + 1
			and fake.calls.back().args.get("category") == category,
			"Pressing %s forwards that category once" % category)

	# A cooled-down or exhausted row refuses programmatic presses too: a stale
	# focus ring must not turn into an intent.
	panel.open_panel(_view_with_daily(1, 5, 0, 120.0))
	select_target(0)
	before = fake.calls.size()
	_say_button("greet").pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before,
		"A disabled row refuses a programmatic press instead of sending an intent")

	# The reply map covers every rule reply kind, and the panel shows the Chinese
	# text; an unknown kind is displayed verbatim rather than dropped.
	_expect(_reply_map_complete(),
		"Every rule reply kind has a Chinese reply label")
	panel.open_panel(_view(true))
	select_target(1)
	fake.dialogue_result.emit({"ok": true, "duplicate": false, "reply_kind": "reply_greet_warm"})
	await process_frame
	_expect(_status() == str(DialoguePanel.REPLY_LABELS["reply_greet_warm"]),
		"A successful reply shows the Chinese text for its reply kind")
	fake.dialogue_result.emit({"ok": true, "duplicate": false, "reply_kind": "reply_thanks_neutral"})
	await process_frame
	_expect(_status() == str(DialoguePanel.REPLY_LABELS["reply_thanks_neutral"]),
		"A different reply kind shows its own text")
	fake.dialogue_result.emit({"ok": true, "duplicate": false, "reply_kind": "reply_future_kind"})
	await process_frame
	_expect(_status() == "reply_future_kind",
		"An unknown reply kind is shown verbatim")

	# The recent list renders the reply kinds the authority sent, in order.
	panel.open_panel(_view_with_recent())
	_expect(_list("RecentList").get_child_count() == 2,
		"The recent section renders every authoritative recent reply")
	_expect(_recent_text(0).contains("林婶")
		and _recent_text(0).contains(str(DialoguePanel.REPLY_LABELS["reply_invite_consider"]))
		and _recent_text(0).contains("UTC 1800052810"),
		"A recent row shows the resident, the Chinese reply and the time")
	_expect(_recent_text(1).contains("reply_future_kind"),
		"An unknown recent reply kind is still shown verbatim")
	var replacement: Dictionary = _view(true)
	replacement.recent = []
	panel.open_panel(replacement)
	_expect(_has_text(_list("RecentList"), "还没有对话记录。"),
		"A reply without recent rows clears the list instead of merging")

	# A refusal shows the authority's own text and leaves the view untouched; a
	# missing text falls back to the reason code, the Chinese map, or verbatim.
	var rows_before: int = panel.residents.size()
	fake.dialogue_result.emit({"ok": false, "reason": "cooldown",
		"reason_text": "这位居民刚和你聊过，请稍后再来。"})
	await process_frame
	_expect(_status() == "这位居民刚和你聊过，请稍后再来。",
		"A refused dialogue shows the authority's reason text")
	_expect(panel.residents.size() == rows_before,
		"A refusal without a state leaves the confirmed view untouched")
	fake.dialogue_result.emit({"ok": false, "reason": "low_affinity", "reason_text": ""})
	await process_frame
	_expect(_status() == str(DialoguePanel.REASON_LABELS["low_affinity"]),
		"A refusal without a reason text uses the Chinese reason label")
	fake.dialogue_result.emit({"ok": false, "reason": "some_future_reason"})
	await process_frame
	_expect(_status() == "some_future_reason",
		"An unknown refusal reason is shown verbatim")

	# A duplicate reply names the duplicate, not a fresh success.
	fake.dialogue_result.emit({"ok": true, "duplicate": true, "reply_kind": "reply_greet_warm"})
	await process_frame
	_expect(_status() == "这次对话已经记录过了。", "A duplicate reply is reported")

	# A `state` read is a view refresh, not a conversation: it carries no reply
	# kind and must not claim that a line was recorded.
	panel.show_status("")
	fake.dialogue_result.emit({"ok": true, "action": "state", "duplicate": false,
		"reply_kind": "", "state": _view(true)})
	await process_frame
	_expect(_status() == "",
		"A state read does not add a 'recorded' status of its own")

	# A successful reply's state replaces the whole view: rows removed by the
	# authority do not linger.
	var single: Dictionary = _view(true)
	single.residents = [_row(ZHOU, 0, 5, 0.0)]
	single.recent = []
	fake.dialogue_result.emit({"ok": true, "duplicate": false,
		"reply_kind": "reply_greet_neutral", "state": single})
	await process_frame
	_expect(panel.residents.size() == 1
		and panel.find_child("Dialogue_" + LIN, true, false) == null,
		"A reply's state replaces the resident rows instead of merging them")

	# Refreshing asks the caller for one authoritative state request.
	before = fake.calls.size()
	var refresh: Button = panel.find_child("Refresh", true, false) as Button
	refresh.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1
		and fake.calls.back().action == "state"
		and fake.calls.back().request_id == "dialogue-state",
		"Refreshing sends one dialogue state request")

	# Malformed payloads and rows do not crash the panel.
	panel.apply_result({})
	panel.apply_result({"state": {"available": true, "residents": [
		"bad", {}, {"id": ""}, {"id": XU, "display_name": "许伯"},
	], "recent": ["bad", {}]}})
	await process_frame
	_expect(panel.residents.size() == 1 and panel.residents[0].get("id") == XU,
		"Malformed rows are skipped and a bare resident row still renders")

	# Esc closes the panel and returns focus to the button that opened it.
	panel.open_panel(_view(true))
	var focus_owner: Control = root.gui_get_focus_owner()
	_expect(focus_owner != null and panel.is_ancestor_of(focus_owner),
		"Opening the dialogue panel captures keyboard focus inside it")
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(not panel.is_open(), "Esc closes the dialogue panel")
	_expect(closes == 1, "Closing the panel emits exactly one close signal")
	_expect(root.gui_get_focus_owner() == opener,
		"Closing returns keyboard focus to the HUD button that opened the panel")
	esc.pressed = false
	root.push_input(esc)
	root.push_input(esc)
	await process_frame
	_expect(closes == 1, "Esc after closing is ignored")
	_finish()


func _forward_intent(action: String, args: Dictionary) -> void:
	var payload: Dictionary = args.duplicate(true)
	fake.request_dialogue(str(payload.get("command_id", "")), action, payload)


func _request_refresh() -> void:
	fake.request_dialogue("dialogue-state", "state")


func select_target(index: int) -> void:
	var target: OptionButton = _target()
	target.select(index)
	target.item_selected.emit(index)


## A member view with one ready resident, one cooled-down resident and one
## resident whose day is partly used.
func _unavailable(reason: String) -> Dictionary:
	return {
		"available": false, "reason": reason, "viewer": PLAYER, "is_member": false,
		"now_utc": 1800052820.0, "residents": [], "recent": [],
	}


func _view(available: bool) -> Dictionary:
	return {
		"available": available, "reason": "" if available else "not_open",
		"viewer": PLAYER, "is_member": available, "now_utc": 1800052820.0,
		"residents": [
			_row(ZHOU, 0, 5, 120.0),
			_row(XU, 1, 5, 0.0),
			_row(LIN, 2, 5, 0.0),
		],
		"recent": [],
	}


func _view_with_daily(daily: int, limit: int, index: int, cooldown: float) -> Dictionary:
	var rows: Array = [_row(ZHOU, 0, 5, 0.0), _row(XU, 1, 5, 0.0), _row(LIN, 2, 5, 0.0)]
	rows[index] = _row(_ids(rows)[index], daily, limit, cooldown)
	return {
		"available": true, "reason": "", "viewer": PLAYER, "is_member": true,
		"now_utc": 1800052820.0, "residents": rows, "recent": [],
	}


func _view_with_recent() -> Dictionary:
	var next: Dictionary = _view(true)
	next.recent = [
		{"command_id": "dlg_a", "npc_id": LIN, "category": "invite",
			"reply_kind": "reply_invite_consider", "tone": "warm",
			"affinity_delta": 2, "at_utc": 1800052810.0},
		{"command_id": "dlg_b", "npc_id": XU, "category": "thank",
			"reply_kind": "reply_future_kind", "tone": "neutral",
			"affinity_delta": 1, "at_utc": 1800052815.0},
	]
	return next


func _row(npc_id: String, daily: int, limit: int, cooldown: float) -> Dictionary:
	return {
		"id": npc_id, "display_name": _display_name(npc_id),
		"affinity": 10, "last_dialogue_utc": 1800052812.0 if cooldown > 0.0 else 0.0,
		"daily_affinity": daily, "daily_limit": limit,
		"cooldown_seconds": NpcDialogue.COOLDOWN_SECONDS,
		"cooldown_remaining": cooldown, "ready": cooldown <= 0.0,
	}


func _display_name(npc_id: String) -> String:
	match npc_id:
		LIN:
			return "林婶"
		XU:
			return "许伯"
		_:
			return "阿舟"


func _reply_map_complete() -> bool:
	for kind: String in NpcDialogue.REPLY_KINDS:
		if not DialoguePanel.REPLY_LABELS.has(kind):
			return false
		var text: String = str(DialoguePanel.REPLY_LABELS[kind])
		if text.is_empty() or text == kind:
			return false
	return DialoguePanel.REPLY_LABELS.size() == NpcDialogue.REPLY_KINDS.size()


func _target() -> OptionButton:
	return panel.find_child("TargetSelect", true, false) as OptionButton


func _action_section() -> VBoxContainer:
	return panel.find_child("ActionSection", true, false) as VBoxContainer


func _list(node_name: String) -> VBoxContainer:
	return panel.find_child(node_name, true, false) as VBoxContainer


func _say_button(category: String) -> Button:
	return panel.find_child("Say_" + category, true, false) as Button


func _say_button_count() -> int:
	var count: int = 0
	for category: String in NpcDialogue.CATEGORIES:
		if _say_button(category) != null:
			count += 1
	return count


func _label_text(node_name: String) -> String:
	var label: Label = panel.find_child(node_name, true, false) as Label
	return label.text if label != null else ""


func _status_line() -> String:
	return _label_text("DialogueStatus")


func _status() -> String:
	return _label_text("Status")


func _hint() -> String:
	return _label_text("ActionHint")


func _recent_text(index: int) -> String:
	var label: Label = _list("RecentList").get_child(index) as Label
	return label.text if label != null else ""


func _ids(rows: Array) -> Array[String]:
	var ids: Array[String] = []
	for row_value: Variant in rows:
		ids.append(str((row_value as Dictionary).get("id", "")))
	return ids


func _has_text(node: Node, fragment: String) -> bool:
	if node == null:
		return false
	for child: Node in node.get_children():
		if child is Label and (child as Label).text.contains(fragment):
			return true
		if _has_text(child, fragment):
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("DIALOGUE_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
