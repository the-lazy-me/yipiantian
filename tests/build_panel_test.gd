extends SceneTree
## 宅基面板作为视图：它只根据建筑状态决定显示什么，并把点击变成建造或拆除
## 意图；槽位能不能建、是不是房主由权威决定。
##
## 没有网络：视图直接构造，面板不在这里发起任何请求。

const BuildPanel = preload("res://ui/build_panel.gd")
const Catalog = preload("res://farm/building_catalog.gd")

const NOW: float = 1800000000.0
const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"

var panel: BuildPanel
var events: Array = []
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = BuildPanel.new()
	panel.name = "Homes"
	root.add_child(panel)
	panel.build_requested.connect(func(slot_id: String, blueprint: String) -> void:
		events.append({"action": "build", "slot": slot_id, "blueprint": blueprint}))
	panel.demolish_requested.connect(func(slot_id: String) -> void:
		events.append({"action": "demolish", "slot": slot_id}))
	await process_frame
	_expect(not panel.is_open(), "The panel starts closed until the player opens it")

	panel.present({}, NOW, ALICE)
	_expect(panel.find_child("Slot_" + Catalog.SLOTS[0], true, false) != null,
		"Every yard slot is listed even when the world has no buildings")
	var picker: OptionButton = panel.find_child("Blueprint_" + Catalog.SLOTS[0], true, false) as OptionButton
	_expect(picker != null and picker.item_count == Catalog.blueprint_ids().size(),
		"An empty slot offers every blueprint")
	_expect(panel.find_child("Build_" + Catalog.SLOTS[0], true, false) != null,
		"An empty slot offers a build action")

	# One slot under construction, one finished house of my own, one of a
	# neighbour's.
	var buildings: Dictionary = {
		"yard_b": {"blueprint": "cottage", "name": "小屋", "owner": ALICE,
			"started_utc": NOW - 60.0, "done_utc": NOW + 240.0, "state": "building"},
		"yard_c": {"blueprint": "workshop", "name": "工坊", "owner": ALICE,
			"started_utc": NOW - 2000.0, "done_utc": NOW - 800.0, "state": "done"},
		"yard_d": {"blueprint": "pavilion", "name": "凉亭", "owner": BOB,
			"started_utc": NOW - 2000.0, "done_utc": NOW - 100.0, "state": "done"},
	}
	panel.present(buildings, NOW, ALICE)
	var building: Label = panel.find_child("State_yard_b", true, false) as Label
	_expect(building != null and building.text.contains("小屋") and building.text.contains("施工中"),
		"A building slot says what is being built and that it is not done")
	_expect(building != null and building.text.contains("4 分钟"),
		"The remaining time follows the world clock (got %s)" % (building.text if building else "null"))
	var finished: Label = panel.find_child("State_yard_c", true, false) as Label
	_expect(finished != null and finished.text.contains("已建成"), "A finished house says so")
	_expect(panel.find_child("Demolish_yard_c", true, false) != null,
		"My own house offers demolition")
	var cancel: Button = panel.find_child("Demolish_yard_b", true, false) as Button
	_expect(cancel != null and cancel.text.contains("取消"), "A building of mine offers cancelling")
	_expect(panel.find_child("Demolish_yard_d", true, false) == null,
		"A neighbour's house offers me nothing")

	# The same view seen by the other player: my actions disappear.
	panel.present(buildings, NOW, BOB)
	_expect(panel.find_child("Demolish_yard_c", true, false) == null,
		"Someone else's view does not offer demolishing my house")
	_expect(panel.find_child("Demolish_yard_d", true, false) != null,
		"The owner sees their own house's demolition")

	# Intents: one click, one named action with the chosen blueprint.
	panel.present(buildings, NOW, BOB)
	var build_button: Button = panel.find_child("Build_" + Catalog.SLOTS[0], true, false) as Button
	build_button.pressed.emit()
	_expect(events.size() == 1 and events[0].action == "build"
		and events[0].slot == Catalog.SLOTS[0]
		and events[0].blueprint == str(Catalog.blueprint_ids()[0]),
		"Building states the slot and the blueprint the player chose")
	var picker_b: OptionButton = panel.find_child("Blueprint_" + Catalog.SLOTS[0], true, false) as OptionButton
	picker_b.select(1)
	build_button.pressed.emit()
	_expect(events.size() == 2 and events[1].blueprint == str(Catalog.blueprint_ids()[1]),
		"Choosing another blueprint is carried into the intent")
	var demolish: Button = panel.find_child("Demolish_yard_d", true, false) as Button
	demolish.pressed.emit()
	_expect(events.size() == 3 and events[2].action == "demolish" and events[2].slot == "yard_d",
		"Demolishing names the slot")

	# Blueprint choice survives a rebuild instead of snapping back to the first
	# entry; read-only visitors keep the list but lose every write.
	panel.present(buildings, NOW, ALICE)
	var chosen_picker: OptionButton = panel.find_child("Blueprint_" + Catalog.SLOTS[0], true, false) as OptionButton
	chosen_picker.select(1)
	var chosen: String = str(chosen_picker.get_item_metadata(1))
	panel.present(buildings, NOW, ALICE)
	var rebuilt_picker: OptionButton = panel.find_child("Blueprint_" + Catalog.SLOTS[0], true, false) as OptionButton
	_expect(rebuilt_picker.selected == 1
		and str(rebuilt_picker.get_item_metadata(rebuilt_picker.selected)) == chosen,
		"A rebuild keeps the blueprint chosen for each empty slot")
	panel.show_status("这块宅基已经有房子了")
	panel.present(buildings, NOW, ALICE)
	_expect(panel._status.text.contains("已经有房子"), "A rebuild keeps the last refusal message")

	panel.present(buildings, NOW, BOB, true, "访客只能查看宅基，不能建造或拆除。")
	var read_only: Label = panel.find_child("ReadOnly", true, false) as Label
	_expect(read_only != null and read_only.visible and read_only.text.contains("访客"),
		"A visitor sees why the homestead is read-only")
	_expect((panel.find_child("Build_" + Catalog.SLOTS[0], true, false) as Button).disabled,
		"Read-only mode disables building")
	_expect((panel.find_child("Blueprint_" + Catalog.SLOTS[0], true, false) as OptionButton).disabled,
		"Read-only mode disables choosing a blueprint")
	_expect((panel.find_child("Demolish_yard_d", true, false) as Button).disabled,
		"Read-only mode disables demolishing my own house")

	# Focus ownership and wrapping, with the opener representing the HUD button.
	var opener := Button.new()
	opener.text = "opener"
	root.add_child(opener)
	opener.grab_focus()
	panel.present(buildings, NOW, ALICE)
	panel.show()
	await process_frame
	var focus_owner: Control = root.gui_get_focus_owner()
	_expect(focus_owner != null and panel.is_ancestor_of(focus_owner),
		"Opening the homestead captures keyboard focus inside the panel")
	var scroll: ScrollContainer = panel.find_child("Scroll", true, false) as ScrollContainer
	_expect(scroll != null and scroll.follow_focus,
		"The homestead list scrolls to follow keyboard focus")
	var focus_build: Button = panel.find_child("Build_" + Catalog.SLOTS[0], true, false) as Button
	focus_build.grab_focus()
	panel.present(buildings, NOW, ALICE)
	var restored: Control = root.gui_get_focus_owner()
	_expect(restored != null and restored.name == focus_build.name and restored != focus_build,
		"Refreshing the homestead restores focus to the same slot's build button")
	var close: Button = panel.find_child("Close", true, false) as Button
	close.grab_focus()
	var tab_event := InputEventKey.new()
	tab_event.keycode = KEY_TAB
	tab_event.pressed = true
	root.push_input(tab_event)
	await process_frame
	var wrapped: Control = root.gui_get_focus_owner()
	_expect(wrapped != null and wrapped != close and panel.is_ancestor_of(wrapped),
		"Real Tab input wraps from the last homestead control back into the list")
	tab_event.pressed = false
	root.push_input(tab_event)
	close.pressed.emit()
	await process_frame
	_expect(root.gui_get_focus_owner() == opener,
		"Closing returns keyboard focus to the control that opened the homestead")
	_finish()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("BUILD_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
