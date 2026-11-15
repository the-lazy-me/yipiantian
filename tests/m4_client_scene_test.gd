extends SceneTree
## The real farm scene attached to a real authority.
##
## A pasted join code locates a running `world_server.gd`, pins its certificate
## and carries the invitation. The scene then renders the authority's world and
## sends soil work back over WSS: nothing is decided locally, and a local-only
## edit (the courtyard) is refused with a visible reason instead of silently
## diverging.
##
## Everything runs under .local/verification.

const WorldClient = preload("res://world/world_client.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const SettingsStore = preload("res://settings/settings_store.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const START: float = 1800000000.0
const WORLD: String = "world-client"

var dir: String = ""
var world_dir: String = ""
var server_pid: int = 0
var port: int = 0
var checks: int = 0
var failures: Array[String] = []
var client: WorldClient
var state: Dictionary = {}
var scene: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(".local/verification/m4-client-scene-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	port = _free_port()
	_expect(port > 0, "A free loopback port is available")
	if port <= 0:
		_finish()
		return
	var args := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % START, "--run-seconds=0",
	])
	server_pid = OS.create_process(OS.get_executable_path(), args, false)
	_expect(server_pid > 0, "The authority process starts")
	if server_pid <= 0:
		_finish()
		return
	if not await _wait_file(world_dir.path_join("server-status.json"), 20000):
		_expect(false, "The authority reports ready")
		_finish()
		return
	var status: Dictionary = _read_json(world_dir.path_join("server-status.json"))
	_expect(str(status.get("state", "")) == "running", "The authority is serving the world")

	# Exactly what a friend receives: one string with the endpoint, the pinned
	# certificate and the invitation.
	var invite_bytes: PackedByteArray = FileAccess.get_file_as_bytes(world_dir.path_join("invite.bin"))
	var grant: Dictionary = WorldInvite.make("server-invite", invite_bytes,
		WorldInvite.MEMBER, WORLD, 0.0, false)
	var pem: String = FileAccess.get_file_as_bytes(
		world_dir.path_join("server.crt")).get_string_from_ascii()
	var code: String = WorldJoinCode.encode(grant, "wss://127.0.0.1:%d" % port, pem, "localhost")
	_expect(code.begins_with(WorldJoinCode.PREFIX), "A join code is built from what the host created")

	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(farm: RefCounted, decorations: RefCounted, now: float) -> void:
		state = {"farm": farm, "decorations": decorations, "now_utc": now})
	var refused: Array[String] = []
	client.refused.connect(func(reason: String) -> void: refused.append(reason))
	client.lost.connect(func(reason: String) -> void: refused.append(reason))
	client.committed.connect(func(request_id: String, reply: Dictionary) -> void:
		print("CLIENT_REPLY %s %s" % [request_id, JSON.stringify(reply)]))
	_expect(client.start(code, "player_00000000000000000000000000000001", "阿青"),
		"The client accepts the join code")
	var arrived: bool = await _wait(func() -> bool: return not state.is_empty() or not refused.is_empty(), 20000)
	_expect(arrived and state.has("farm"), "The client receives the authoritative world")
	if not state.has("farm"):
		_expect(false, "Refusal reason observed: %s" % str(refused))
		await _stop_server()
		_finish()
		return

	scene = load("res://scenes/main.tscn").instantiate()
	scene.store = null
	scene.settings_store = SettingsStore.new(dir.path_join("preferences"))
	scene.remote = client
	scene.remote_seed = state
	root.add_child(scene)
	await create_timer(0.6).timeout
	_expect(scene._loaded, "The farm scene loads the shared world")
	_expect(scene.farm.visible, "The farm is visible without a local save")
	_expect(scene.farm_state.snapshot().harvested.greens == 0, "The shared world starts unharvested")
	var clock_gap: float = absf(scene.clock.call() - START)
	_expect(clock_gap < 120.0, "The scene clock follows the world clock (gap %.1fs)" % clock_gap)

	# A yard slot built through the authority must appear in the shared scene as
	# an unfinished house, and demolition must remove that node again. No extra
	# network message is involved: both changes arrive on the normal reply.
	scene._send_build("yard_a", "cottage")
	var housed: bool = await _wait(func() -> bool:
		return scene.housing_view != null and scene.housing_view.is_showing("yard_a"), 8000)
	var yard: Node3D = null
	if scene.housing_view != null:
		yard = scene.housing_view.get_node_or_null("yard_a") as Node3D
	_expect(housed and yard != null and yard.find_child("Foundation", true, false) != null,
		"A build through the authority appears as an unfinished yard house")
	scene._send_demolish("yard_a")
	var cleared: bool = await _wait(func() -> bool:
		return scene.housing_view != null and not scene.housing_view.is_showing("yard_a"), 8000)
	_expect(cleared, "A demolished yard house disappears from the shared world")

	# The same gesture a player makes on a mature bed. Each click reprojects the
	# cell: focusing the camera moves it, so a cached screen point lands on
	# whatever happens to be under the old position.
	await _click(_soil_point())
	await create_timer(0.85).timeout
	await _click(_soil_point())
	scene._open_palette("tools")
	await create_timer(0.3).timeout
	var harvest: Button = scene.get_node("HUD/Layout/ToolChoices/Harvest")
	await _click(harvest.get_global_rect().get_center())
	await _click(_soil_point())
	print("CLIENT_STATE field=%d cell=%s tool=%s tools=%s notice=%s joined=%s member=%s lost=%s" % [
		scene.selected_field, scene.selected_cell, scene.selected_tool,
		scene._tools_available(), scene.hud._notice.text, scene.remote.joined,
		scene.remote.member.is_joined() if scene.remote.member != null else "null",
		str(refused)])
	var harvested: bool = await _wait(func() -> bool:
		return scene.farm_state.snapshot().harvested.greens == 1, 8000)
	_expect(harvested, "A harvest goes through the authority and comes back applied")
	_expect(scene.farm_state.get_cell("field_03", "cell_06").stage == "empty",
		"The harvested cell is empty in the shared world")

	# The neighbourhood panel reads the authoritative social view and the roster.
	var neighbours: Button = scene.hud.get_node("Layout/FarmControls/Neighbors")
	_expect(neighbours.visible, "A shared world shows the neighbours entry")
	_expect(not scene.hud.get_node("Layout/FarmControls/BuildIsland").visible
		and not scene.hud.get_node("Layout/FarmControls/OpenBasket").visible,
		"Local-only tools are hidden in a shared world")
	neighbours.pressed.emit()
	var view_ready: bool = await _wait(func() -> bool:
		return not scene.social_panel.view.is_empty(), 8000)
	_expect(view_ready and str(scene.social_panel.view.get("name", "")) == "阿青",
		"The panel receives the player's own social view from the authority")
	_expect(scene.social_panel._online.get_child(0).text.contains("阿青"),
		"The panel lists the player from the authoritative roster")

	# A local-only edit would fork this client's copy; it must be refused loudly.
	scene._begin_decoration()
	_expect(not scene.decoration_layout.active, "The courtyard editor stays closed in a shared world")
	_expect(scene.hud._notice.visible and scene.hud._notice.text.contains("房主"),
		"The refusal is visible to the player")

	await _stop_server()
	var saved: Dictionary = _read_json(world_dir.path_join("farm.json"))
	var farm: Dictionary = saved.get("farm", {}) as Dictionary
	var harvested_map: Dictionary = farm.get("harvested", {}) as Dictionary
	_expect(int(harvested_map.get("greens", 0)) == 1,
		"The authority persisted the harvest once")

	# A neighbour's action is announced with their own name, and an anonymous
	# member is not given an invented one.
	scene._announce_neighbour({"from_name": "小满", "reward_crop_id": "greens"},
		{"kind": "harvest"})
	await process_frame
	_expect(scene.hud._notice.visible and scene.hud._notice.text == "小满 收了青菜",
		"A named neighbour's harvest is announced with the crop name")
	scene.hud._notice.hide()
	scene._announce_neighbour({"from_name": ""}, {"kind": "harvest"})
	await process_frame
	_expect(not scene.hud._notice.visible,
		"An anonymous neighbour is not announced under a made-up name")
	scene._announce_neighbour({"from_name": "小满"},
		{"kind": "gift", "crop_id": "greens", "to_id": "player_00000000000000000000000000000001"})
	await process_frame
	_expect(scene.hud._notice.visible and scene.hud._notice.text == "小满 送了你一份青菜",
		"A gift addressed to this player says so")
	scene._announce_neighbour({"from_name": "小满"},
		{"kind": "gift", "crop_id": "greens", "to_id": "player_00000000000000000000000000000002"})
	await process_frame
	_expect(scene.hud._notice.text == "小满 送给邻居一份青菜",
		"A gift to someone else is not addressed to this player")

	# A neighbour's broadcast is replayed under their own id: their harvest must
	# land in their bag here too, not in this player's.
	scene.farm_state.mature_all_crops(START)
	var mine: Dictionary = scene.farm_state.bag("player_00000000000000000000000000000001")
	var theirs_before: Dictionary = scene.farm_state.bag("player_00000000000000000000000000000002")
	scene._on_remote_changed({"from_id": "player_00000000000000000000000000000002",
		"from_name": "小满", "reward_crop_id": "greens",
		"command": {"id": "neighbour-harvest-1", "kind": "harvest", "field_id": "field_04",
			"cell_id": "cell_06", "at_utc": START, "authorized": false}})
	await process_frame
	_expect(scene.farm_state.bag("player_00000000000000000000000000000002").greens == theirs_before.greens + 1,
		"A named neighbour's harvest is credited to that neighbour")
	_expect(scene.farm_state.bag("player_00000000000000000000000000000001").greens == mine.greens,
		"A neighbour's harvest never lands in this player's bag")
	# An anonymous broadcast credits nobody's bag, exactly as the authority does.
	scene._on_remote_changed({"from_id": "", "from_name": "", "reward_crop_id": "radish",
		"command": {"id": "anon-harvest-1", "kind": "harvest", "field_id": "field_05",
			"cell_id": "cell_06", "at_utc": START, "authorized": false}})
	await process_frame
	_expect(int(scene.farm_state.snapshot().inventory.radish) > 0,
		"An anonymous member's harvest goes to the shared store")
	_expect(scene.farm_state.bag("player_00000000000000000000000000000002").radish == theirs_before.radish,
		"Anonymous work is not credited to a named neighbour either")
	_finish()


# ------------------------------------------------------------------ helpers

func _soil_point() -> Vector2:
	return scene.camera.unproject_position(
		scene.farm.fields[2].to_global(scene.farm.cell_center("cell_06")))


func _stop_server() -> void:
	if server_pid <= 0:
		return
	var marker := FileAccess.open(world_dir.path_join("stop"), FileAccess.WRITE)
	if marker != null:
		marker.store_string("stop")
		marker.close()
	var deadline: int = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline and OS.is_process_running(server_pid):
		await create_timer(0.05).timeout
	server_pid = 0


func _click(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	await process_frame
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		root.push_input(event, true)
		await physics_frame
		await process_frame


func _wait(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _wait_file(path: String, timeout_ms: int) -> bool:
	return await _wait(func() -> bool: return FileAccess.file_exists(path), timeout_ms)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _free_port() -> int:
	var probe := TCPServer.new()
	if probe.listen(0, "127.0.0.1") != OK:
		return 0
	var chosen: int = probe.get_local_port()
	probe.stop()
	return chosen


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("M4_CLIENT_SCENE_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
