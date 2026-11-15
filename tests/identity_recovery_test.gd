extends SceneTree
## 身份材料的备份、迁移与重置演练：整目录迁移保留绑定，只迁移导出包退化为
## TOFU，丢失 player.key 后无法再用原 id 加入，房主删除条目后可以重新绑定。
##
## 没有网络：直接驱动 WorldHost 的绑定入口与 PlayerProfile 的凭据文件，文件
## 操作都在 .local/verification 下的临时目录里。

const WorldHost = preload("res://world/world_host.gd")
const PlayerBindingState = preload("res://world/player_binding_state.gd")
const PlayerProfile = preload("res://social/player_profile.gd")

const START: float = 1800000000.0
const WORLD: String = "world-recovery"
const ALICE: String = "player_recovery_00000000000000000001"

var checks: int = 0
var failures: Array[String] = []
var dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir() \
		.path_join(".local/verification/identity-recovery-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var origin: String = dir.path_join("world")
	var host: WorldHost = _open_host("Origin", origin)
	_expect(host != null, "The original world opens")
	if host == null:
		_finish()
		return
	var profile_dir: String = dir.path_join("profile")
	var profile := PlayerProfile.new(profile_dir)
	var loaded: Dictionary = profile.load_profile()
	_expect(bool(loaded.get("ok", false)), "The player profile loads")
	var proof: String = PlayerBindingState.proof(
		Marshalls.raw_to_base64(profile.player_secret), WORLD)
	_expect(bool(host._verify_player(ALICE, proof).get("ok", false)),
		"The original world binds the player's proof")
	_free_host(host)

	_test_whole_directory_migration(origin, profile, proof)
	_test_export_only_migration(origin)
	_test_lost_key(profile_dir, proof)
	_test_host_reset(origin, profile, proof)
	_test_restore_backup(origin, proof)
	_finish()


## 备份/迁移按自托管文档的约定整目录复制：绑定随目录走。
func _test_whole_directory_migration(origin: String, profile: PlayerProfile,
		proof: String) -> void:
	var moved: String = dir.path_join("migrated-world")
	_expect(_copy_dir(origin, moved), "The world directory copies whole")
	var host: WorldHost = _open_host("Migrated", moved)
	if host == null:
		return
	_expect(host.player_bindings.players.has(ALICE),
		"The copied directory carries the binding")
	_expect(bool(host._verify_player(ALICE, proof).get("ok", false)),
		"The same credential still joins after a directory migration")
	var wrong: String = PlayerBindingState.proof(
		Marshalls.raw_to_base64(Crypto.new().generate_random_bytes(32)), WORLD)
	_expect(str(host._verify_player(ALICE, wrong).get("reason", "")) == "player_proof",
		"A foreign credential is still refused on the migrated world")
	_free_host(host)
	var copied_profile: String = dir.path_join("migrated-profile")
	_expect(_copy_dir(dir.path_join("profile"), copied_profile),
		"The profile directory copies whole")
	var relaunched := PlayerProfile.new(copied_profile)
	relaunched.load_profile()
	_expect(relaunched.player_id == profile.player_id,
		"The copied profile keeps the same id")
	_expect(relaunched.player_secret == profile.player_secret,
		"The copied profile keeps the same credential file")


## 只拿到“导出世界”的 world.json 时没有 player_bindings.json：身份层退化为 TOFU。
func _test_export_only_migration(origin: String) -> void:
	var exported: String = dir.path_join("exported-world")
	DirAccess.make_dir_recursive_absolute(exported)
	# The export package carries the farm but not the sidecar; this directory
	# starts with neither, which is the same identity-layer shape.
	_expect(not FileAccess.file_exists(exported.path_join("player_bindings.json")),
		"An export-only directory has no binding document")
	var host: WorldHost = _open_host("Exported", exported)
	if host == null:
		return
	_expect(host.player_bindings.players.is_empty(),
		"The export-only world starts with no bindings")
	var fresh: String = PlayerBindingState.proof(
		Marshalls.raw_to_base64(Crypto.new().generate_random_bytes(32)), WORLD)
	_expect(bool(host._verify_player(ALICE, fresh).get("ok", false)),
		"An unbound id is claimed on first use, so migration degrades to TOFU")
	_expect(str(host._verify_player(ALICE, PlayerBindingState.proof(
		Marshalls.raw_to_base64(Crypto.new().generate_random_bytes(32)), WORLD))
		.get("reason", "")) == "player_proof",
		"Once claimed, the export-only world enforces the new binding")
	_free_host(host)


## 丢失 player.key：档案会生成新凭据，原世界按不同证明拒绝；旧 id 仍可本地使用。
func _test_lost_key(profile_dir: String, proof: String) -> void:
	var replacement: String = dir.path_join("replacement-profile")
	DirAccess.make_dir_recursive_absolute(replacement)
	var fresh := PlayerProfile.new(replacement)
	fresh.load_profile()
	_expect(not (fresh.player_secret == PackedByteArray()),
		"A replacement installation mints a new credential")
	var fresh_proof: String = PlayerBindingState.proof(
		Marshalls.raw_to_base64(fresh.player_secret), WORLD)
	_expect(fresh_proof != proof, "The replacement credential yields a different proof")
	var host: WorldHost = _open_host("LostKey", dir.path_join("world"))
	if host == null:
		return
	# The origin world was reopened for this check; it already holds the binding.
	_expect(str(host._verify_player(ALICE, fresh_proof).get("reason", ""))
		== "player_proof",
		"A lost key cannot reclaim the bound id, even with the old id text")
	_free_host(host)
	# The damaged-file path is covered by PLAYER_IDENTITY_TEST; here the operator's
	# only recovery is restoring player.key or asking the host to reset.
	_expect(FileAccess.file_exists(profile_dir.path_join(PlayerProfile.SECRET_FILE)),
		"The original credential file is still on disk for restoration")


## 房主重置：停服务端后删除该 id 的条目，下一次加入重新绑定。
func _test_host_reset(origin: String, profile: PlayerProfile, proof: String) -> void:
	var reset_dir: String = dir.path_join("reset-world")
	_expect(_copy_dir(origin, reset_dir), "The world copies before a reset")
	var path: String = reset_dir.path_join("player_bindings.json")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_expect(parsed is Dictionary, "The binding document is readable")
	if not parsed is Dictionary:
		return
	var document: Dictionary = parsed
	var state: Variant = document.get("state")
	if not state is Dictionary:
		_expect(false, "The binding document has a state object")
		return
	var players: Variant = (state as Dictionary).get("players")
	_expect(players is Dictionary and (players as Dictionary).has(ALICE),
		"The document holds this player before the reset")
	if not players is Dictionary:
		return
	(players as Dictionary).erase(ALICE)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(document))
	file.close()
	var host: WorldHost = _open_host("Reset", reset_dir)
	if host == null:
		return
	_expect(not host.player_bindings.players.has(ALICE), "The reset removed the entry")
	_expect(bool(host._verify_player(ALICE, proof).get("ok", false)),
		"The original credential rebinds after the host reset")
	_free_host(host)


## 重置前的整目录备份仍保有原绑定：恢复即可回到重置前状态。
func _test_restore_backup(origin: String, proof: String) -> void:
	var restored: String = dir.path_join("restored-world")
	_expect(_copy_dir(origin, restored), "A pre-reset backup can be restored")
	var host: WorldHost = _open_host("Restored", restored)
	if host == null:
		return
	_expect(bool(host._verify_player(ALICE, proof).get("ok", false)),
		"The restored backup accepts the original proof")
	_expect(str(host._verify_player(ALICE, PlayerBindingState.proof(
		Marshalls.raw_to_base64(Crypto.new().generate_random_bytes(32)), WORLD))
		.get("reason", "")) == "player_proof",
		"The restored backup still refuses a foreign proof")
	_free_host(host)


func _open_host(node_name: String, world_dir: String) -> WorldHost:
	if not DirAccess.dir_exists_absolute(world_dir):
		DirAccess.make_dir_recursive_absolute(world_dir)
	var host := WorldHost.new()
	host.name = node_name
	root.add_child(host)
	var opened: Dictionary = host.configure(world_dir, START, WORLD)
	if not bool(opened.get("ok", false)):
		_expect(false, "Opening %s failed: %s" % [world_dir, str(opened.get("reason", ""))])
		root.remove_child(host)
		host.free()
		return null
	return host


func _free_host(host: WorldHost) -> void:
	root.remove_child(host)
	host.free()


func _copy_dir(from: String, to: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(to) != OK:
		return false
	var source := DirAccess.open(from)
	if source == null:
		return false
	for filename: String in source.get_files():
		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(from.path_join(filename))
		var file := FileAccess.open(to.path_join(filename), FileAccess.WRITE)
		if file == null:
			return false
		file.store_buffer(bytes)
		file.close()
	return true


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("IDENTITY_RECOVERY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
