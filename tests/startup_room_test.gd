extends SceneTree
## 真实链路：启动界面 → 联机面板 → 本机开房 → 进入这间房 → 构建联机农场。
##
## 「开房」由启动场景启动本机的无头权威子进程，「进入」使用开房得到的加入码
## 走 WorldClient，最后由农场场景接管房主的 WorldHosting。这里不使用任何桩：
## 按钮、子进程、加入码和农场场景都是真的，所以它也验证了房间随农场退出。
##
## 所有本机状态写在 .local/verification 下；房间目录仍使用产品约定的
## user://rooms/world（开房路径本身就是被测对象）。

const SettingsStore = preload("res://settings/settings_store.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const RoomPanel = preload("res://ui/room_panel.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")

var checks: int = 0
var failures: Array[String] = []
var folder: String = ""
var startup: Node
var panel: RoomPanel
var farm: Node3D
var room_code: String = ""
var visitor_code: String = ""
var room_pid: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	folder = ProjectSettings.globalize_path(
		"res://../.local/verification/startup-room-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(folder)
	root.size = Vector2i(1280, 720)
	# 先写一份偏好，让这次启动走「已加载」路径：首次使用会插入画质选择，
	# 那不属于本测试要验证的链路。两个存档目录都留在隔离目录里。
	var settings := SettingsStore.new(folder.path_join("preferences"))
	var loaded: Dictionary = settings.load_settings()
	var saved: Dictionary = settings.save(SettingsStore.DEFAULTS.duplicate(true))
	_expect(loaded.ok and saved.ok, "隔离的偏好文件可读可写")

	startup = load("res://scenes/startup.tscn").instantiate()
	startup.settings_store = settings
	startup.farm_store = FarmStore.new(folder.path_join("farm"))
	root.add_child(startup)
	current_scene = startup
	await process_frame
	await process_frame

	# 1. 加载界面上的 Neighbors 按钮真的能打开联机面板。
	var neighbours := startup.find_child("Neighbors", true, false) as Button
	_expect(neighbours != null, "加载界面提供 Neighbors 入口")
	if neighbours == null:
		await _cleanup()
		_finish()
		return
	neighbours.pressed.emit()
	await process_frame
	await process_frame
	panel = startup.get_node_or_null("RoomPanel") as RoomPanel
	_expect(panel != null, "点击 Neighbors 创建联机面板")
	_expect(panel != null and panel.is_open(), "联机面板已在加载界面打开")
	if panel == null:
		await _cleanup()
		_finish()
		return

	# 面板已经打开时资源仍在后台线程加载。先等它加载完再开房，让「进入房间」
	# 之后的重建路径是唯一出口；否则测试会依赖资源线程与开房进程谁先完成的
	# 竞争（同一台机器不同运行会得到不同结果）。
	var resources_ready: bool = await _wait(_resources_ready, 30000)
	_expect(resources_ready, "面板打开期间农场资源加载完成")
	if not resources_ready:
		await _cleanup()
		_finish()
		return

	# 2. 点 Host：启动本机权威子进程，拿到可分享的加入码。
	var host := panel.find_child("Host", true, false) as Button
	_expect(host != null, "面板提供 Host 按钮")
	if host == null:
		await _cleanup()
		_finish()
		return
	host.pressed.emit()
	var hosted: bool = await _wait(_room_code_ready, 45000)
	_expect(hosted, "开房在 45 秒内产生加入码")
	if not hosted:
		await _cleanup()
		_finish()
		return
	room_code = panel._room_code.text
	_expect(room_code.begins_with(WorldJoinCode.PREFIX), "房间给出的是 FARMJ1. 加入码")
	visitor_code = panel._visitor_code.text
	_expect(visitor_code.begins_with(WorldJoinCode.PREFIX), "房间同时给出访客照料码")
	_expect(panel._visitor_block.visible, "访客照料码有独立的复制入口")
	var member_grant: Dictionary = (WorldJoinCode.decode(room_code).get("grant", {}) as Dictionary)
	var visitor_grant: Dictionary = (WorldJoinCode.decode(visitor_code).get("grant", {}) as Dictionary)
	_expect(str(member_grant.get("role", "")) == WorldInvite.MEMBER,
		"成员加入码解析为 member")
	_expect(str(visitor_grant.get("role", "")) == WorldInvite.VISITOR,
		"访客照料码解析为 visitor")
	_expect(str(member_grant.get("id", "")) != str(visitor_grant.get("id", "")),
		"成员码与访客码是两条独立授权")
	var visitor_text: String = ""
	for node: Node in panel._visitor_block.find_children("*", "Label", true, false):
		visitor_text += (node as Label).text
	_expect(visitor_text.contains("浇水") and visitor_text.contains("除草"),
		"界面说明访客码只能浇水、除草")
	_expect(visitor_text.contains("撤销"),
		"界面保留加入码泄露与当前没有撤销界面的说明")
	_expect(panel._enter.visible, "开好房后可以进入这间房")

	# 3. 点 Enter：用这串码连接本机权威，再装配联机农场。
	var enter := panel.find_child("Enter", true, false) as Button
	_expect(enter != null, "面板提供 Enter 按钮")
	if enter == null:
		await _cleanup()
		_finish()
		return
	# 档案里的旧名字不能影响这次判断：先清空，确认“没有名字就不进世界”。
	panel._name.text = ""
	enter.pressed.emit()
	await process_frame
	await process_frame
	_expect(panel.is_open() and panel._status.text.contains("名字"),
		"Entering without a name says what is missing instead of joining anonymously")
	panel._name.text = "阿青"
	enter.pressed.emit()
	var arrived: bool = await _wait(_farm_connected, 60000)
	_expect(arrived, "进入房间后农场场景连上了权威")
	var seeded: bool = false
	if arrived:
		seeded = await _wait(_seed_ready, 60000)
	_expect(seeded, "农场场景收到权威世界")
	if not arrived or not seeded:
		_room_diagnostics()
		await _cleanup()
		_finish()
		return

	_expect(not is_instance_valid(panel) or not panel.visible, "进入世界后面板已隐藏")
	_expect(farm.remote_seed.has("farm"), "remote_seed 带有权威农场的 farm")
	var hosted_room: RefCounted = farm.hosted_room
	_expect(hosted_room != null and hosted_room.is_running(),
		"农场运行期间权威进程仍然活着")
	var decoded: Dictionary = WorldJoinCode.decode(room_code)
	_expect(bool(decoded.get("ok", false)), "房间的加入码可以解码")
	_expect(str(decoded.get("url", "")).begins_with("wss://"),
		"解出的端点是房间的 WSS 地址")

	# 4. 房间属于这次会话：农场退出时权威进程也必须退出。
	room_pid = int(hosted_room.pid) if hosted_room != null else 0
	_expect(room_pid > 0, "房间提供了权威进程 pid")
	farm.queue_free()
	var stopped: bool = await _wait(_room_stopped, 12000)
	_expect(stopped, "退出农场后房间的权威进程已结束")

	# 5. 清理启动节点（如果它还没有把自己交给农场场景）。
	await _cleanup()
	_finish()


# ---------------------------------------------------------------- 等待条件

## 面板打开时启动场景会拒绝装配本地农场（`_room_open`），资源就停在
## `_packed` 里等玩家决定。
func _resources_ready() -> bool:
	return is_instance_valid(startup) and startup._packed != null and not startup._loading


func _room_code_ready() -> bool:
	return is_instance_valid(panel) and not panel._room_code.text.is_empty()


## 装配路径可能已经把启动节点自己释放掉，所以农场既要从 startup 找，
## 也要回退到 current_scene。
func _farm_connected() -> bool:
	if is_instance_valid(startup) and startup.farm_scene != null:
		farm = startup.farm_scene
	if farm == null and current_scene != null and current_scene is Node3D \
			and current_scene.get("remote") != null:
		farm = current_scene
	return farm != null and is_instance_valid(farm) and farm.remote != null


func _seed_ready() -> bool:
	return is_instance_valid(farm) and not farm.remote_seed.is_empty()


func _room_stopped() -> bool:
	return room_pid > 0 and not OS.is_process_running(room_pid)


func _wait(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await create_timer(0.1).timeout
	return bool(condition.call())


# ---------------------------------------------------------------- 清理与汇总

func _cleanup() -> void:
	if is_instance_valid(farm):
		farm.queue_free()
	if is_instance_valid(startup):
		var scene: Variant = startup.farm_scene
		if scene != null and is_instance_valid(scene):
			scene.queue_free()
		if startup._hosting != null:
			room_pid = int(startup._hosting.pid)
			startup._hosting.stop()
			startup._hosting = null
		startup.queue_free()
	# 让 queue_free 真正跑到 _exit_tree（房主进程在那里停止）。
	await process_frame
	await process_frame
	await create_timer(0.2).timeout
	# 失败路径留下的权威进程不能活过测试。
	if room_pid > 0 and OS.is_process_running(room_pid):
		OS.kill(room_pid)
		await create_timer(0.2).timeout


func _room_diagnostics() -> void:
	print("ROOM_DIAG startup_valid=%s farm=%s farm_remote=%s seed=%s panel_status=%s" % [
		is_instance_valid(startup),
		is_instance_valid(farm),
		is_instance_valid(farm) and farm.remote != null,
		is_instance_valid(farm) and not farm.remote_seed.is_empty(),
		panel._status.text if is_instance_valid(panel) else "<freed>"])
	if not is_instance_valid(startup):
		return
	print("ROOM_DIAG_STARTUP client=%s state=%s joining=%s room_open=%s packed=%s loading=%s panel_visible=%s farm_scene=%s" % [
		startup._world_client != null,
		not startup._world_state.is_empty(),
		startup._joining,
		startup._room_open,
		startup._packed != null,
		startup._loading,
		panel.visible if is_instance_valid(panel) else "<freed>",
		startup.farm_scene != null])


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("STARTUP_ROOM_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
