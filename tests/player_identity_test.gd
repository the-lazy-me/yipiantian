extends SceneTree
## 玩家身份绑定：世界把 player_id 绑到首个连接出示的 world-scoped 凭据证明，
## 之后的连接必须出示同一证明；本机安装凭据存在 player.key，从不经网络发送。
##
## 没有网络：直接驱动 WorldHost 的绑定入口与 WorldMember 的 join 载荷，并验证
## 侧车文档的重开、损坏与只读行为。真实加入路径见 m4_join 的身份用例。

const WorldHost = preload("res://world/world_host.gd")
const WorldMember = preload("res://world/world_member.gd")
const PlayerBindingState = preload("res://world/player_binding_state.gd")
const PlayerBindingStore = preload("res://world/player_binding_store.gd")
const PlayerProfile = preload("res://social/player_profile.gd")

const START: float = 1800000000.0
const WORLD: String = "world-identity"
const SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtOTk="
const ALICE: String = "player_identity_00000000000000000001"
const BOB: String = "player_identity_00000000000000000002"

var checks: int = 0
var failures: Array[String] = []
var dir: String = ""
var host: WorldHost


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir() \
		.path_join(".local/verification/player-identity-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	host = WorldHost.new()
	host.name = WorldHost.SESSION_NODE_NAME
	root.add_child(host)
	var opened: Dictionary = host.configure(dir.path_join("world"), START, WORLD)
	_expect(bool(opened.get("ok", false)), "The authority opens a world")
	if not bool(opened.get("ok", false)):
		_finish()
		return
	_test_first_bind()
	_test_secret_mismatch()
	_test_reopen()
	_test_read_only()
	_test_state_shape()
	_test_join_payload()
	_test_profile()
	_test_corrupt_and_unsupported()
	_finish()


func _test_first_bind() -> void:
	_expect(host.player_bindings.players.is_empty(), "A fresh world has no bound identities")
	_expect(bool(host._verify_player(ALICE, _proof(SECRET_A)).get("ok", false)),
		"The first claim of an id binds its proof")
	_expect(host.player_bindings.players.has(ALICE),
		"The binding is held in the authority's registry")
	_expect(FileAccess.file_exists(dir.path_join("world").path_join("player_bindings.json")),
		"The first binding is written before the join is accepted")
	_expect(bool(host._verify_player(ALICE, _proof(SECRET_A)).get("ok", false)),
		"The same id with the bound proof is accepted again")
	_expect(bool(host._verify_player(BOB, _proof(SECRET_B)).get("ok", false)),
		"A second id binds independently")


func _test_secret_mismatch() -> void:
	var refused: Dictionary = host._verify_player(ALICE, _proof(SECRET_B))
	_expect(not bool(refused.get("ok", false))
		and str(refused.get("reason", "")) == "player_proof",
		"Another id's proof cannot claim a bound id")
	_expect(bool(host._verify_player(ALICE, _proof(SECRET_A)).get("ok", false)),
		"A refused claim does not overwrite the binding")
	var missing: Dictionary = host._verify_player(ALICE, "")
	_expect(not bool(missing.get("ok", false)), "A missing proof is refused")


func _test_reopen() -> void:
	var reopened := WorldHost.new()
	reopened.name = "Reopened"
	root.add_child(reopened)
	var opened: Dictionary = reopened.configure(dir.path_join("world"), START, WORLD)
	_expect(bool(opened.get("ok", false)), "The authority reopens the same world")
	_expect(bool(reopened._verify_player(ALICE, _proof(SECRET_A)).get("ok", false)),
		"The binding survives a restart")
	_expect(str(reopened._verify_player(ALICE, _proof(SECRET_B)).get("reason", ""))
		== "player_proof", "The refusal survives a restart too")
	root.remove_child(reopened)
	reopened.free()


func _test_read_only() -> void:
	var read_only_dir: String = dir.path_join("read-only")
	DirAccess.make_dir_recursive_absolute(read_only_dir)
	var retired := WorldHost.new()
	retired.name = "Retired"
	retired.read_only = true
	root.add_child(retired)
	var opened: Dictionary = retired.configure(read_only_dir, START, WORLD)
	_expect(bool(opened.get("ok", false)), "A read-only authority opens")
	_expect(bool(retired._verify_player(ALICE, _proof(SECRET_A)).get("ok", false)),
		"A read-only authority admits an unknown id without binding it")
	_expect(not FileAccess.file_exists(read_only_dir.path_join("player_bindings.json")),
		"A read-only authority writes no binding")
	root.remove_child(retired)
	retired.free()


func _test_state_shape() -> void:
	var state: Dictionary = PlayerBindingState.empty_state()
	_expect(PlayerBindingState.valid(state), "The empty registry is a valid document")
	var bound: Dictionary = PlayerBindingState.bind(state, ALICE, SECRET_A, START)
	_expect(bool(bound.get("ok", false)), "Binding produces a candidate")
	var bound_state: Dictionary = bound.state
	_expect(PlayerBindingState.valid(bound_state), "A bound registry is valid")
	_expect(str(PlayerBindingState.bind(bound_state, ALICE, SECRET_B, START).get("reason", ""))
		== "already_bound", "A second bind of the same id is refused")
	_expect(not PlayerBindingState.valid({"players": {ALICE: {"secret": SECRET_A}}}),
		"A registry entry without its creation time is refused")
	_expect(not PlayerBindingState.valid({"players": {ALICE: {
		"secret": SECRET_A, "created_utc": START, "extra": 1}}}),
		"An unknown entry field is refused")
	_expect(not PlayerBindingState.valid({"players": {ALICE: {
		"secret": "AAAA", "created_utc": START}}}),
		"A short credential is refused")
	_expect(not PlayerBindingState.valid({"players": {"bad id": {
		"secret": SECRET_A, "created_utc": START}}}),
		"An invalid player id is refused")
	var store := PlayerBindingStore.new(dir.path_join("state-only"))
	_expect(not bool(store.save_state({"players": {ALICE: {"secret": SECRET_A}}}).get("ok", false)),
		"The store refuses a document the next load would reject")


func _test_join_payload() -> void:
	var anonymous := WorldMember.new()
	anonymous.world_id = WORLD
	_expect(not anonymous.join_payload().has("player_id")
		and not anonymous.join_payload().has("player_proof"),
		"An anonymous join carries no identity")
	anonymous.free()
	var named := WorldMember.new()
	named.world_id = WORLD
	named.player_id = ALICE
	named.display_name = "甲"
	var missing: Dictionary = named.join_payload()
	_expect(str(missing.get("player_id", "")) == ALICE and not missing.has("player_proof"),
		"A named join without a credential sends the id but no proof")
	named.player_secret = Marshalls.base64_to_raw(SECRET_A)
	var payload: Dictionary = named.join_payload()
	_expect(str(payload.get("player_proof", "")) == _proof(SECRET_A),
		"The join carries the world-scoped proof so an unbound id can be bound")
	_expect(str(payload.get("player_proof", "")) != SECRET_A,
		"The installation credential itself never crosses the wire")
	named.world_id = "another-world"
	_expect(str(named.join_payload().get("player_proof", ""))
		!= str(payload.get("player_proof", "")),
		"The proof is scoped to one world; another world sees a different value")
	named.free()


func _test_profile() -> void:
	var profile_dir: String = dir.path_join("profile")
	var first := PlayerProfile.new(profile_dir)
	var loaded: Dictionary = first.load_profile()
	_expect(bool(loaded.get("ok", false)), "The profile loads")
	_expect(first.player_secret.size() == PlayerProfile.SECRET_BYTES,
		"The profile mints a 32-byte credential")
	var key_path: String = profile_dir.path_join(PlayerProfile.SECRET_FILE)
	_expect(FileAccess.file_exists(key_path), "The credential is written beside the id")
	var key_text: String = FileAccess.get_file_as_string(key_path).strip_edges()
	_expect(key_text == Marshalls.raw_to_base64(first.player_secret),
		"The stored credential is the one the profile uses")
	var second := PlayerProfile.new(profile_dir)
	second.load_profile()
	_expect(second.player_secret == first.player_secret,
		"A relaunch presents the same credential")
	_expect(second.player_id == first.player_id, "The id is unchanged too")
	# A damaged key must not mint a new one: the id stays, named joins are refused
	# until the file is restored, and nothing is silently overwritten.
	var damaged := PlayerProfile.new(dir.path_join("profile-damaged"))
	damaged.load_profile()
	var damaged_path: String = dir.path_join("profile-damaged").path_join(
		PlayerProfile.SECRET_FILE)
	var overwrite := FileAccess.open(damaged_path, FileAccess.WRITE)
	overwrite.store_string("not-a-key")
	overwrite.close()
	var damaged_id: String = damaged.player_id
	var reread := PlayerProfile.new(dir.path_join("profile-damaged"))
	var result: Dictionary = reread.load_profile()
	_expect(bool(result.get("ok", false)) and reread.player_id == damaged_id,
		"A damaged key keeps the id usable locally")
	_expect(reread.player_secret.is_empty(),
		"A damaged key is not replaced by a fresh credential")
	_expect(FileAccess.get_file_as_string(damaged_path).strip_edges() == "not-a-key",
		"The damaged key file is left in place for the operator")


func _test_corrupt_and_unsupported() -> void:
	var corrupt_dir: String = dir.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	var file := FileAccess.open(corrupt_dir.path_join("player_bindings.json"), FileAccess.WRITE)
	file.store_string("{not json")
	file.close()
	var corrupt := WorldHost.new()
	corrupt.name = "Corrupt"
	root.add_child(corrupt)
	var refused: Dictionary = corrupt.configure(corrupt_dir, START, WORLD)
	_expect(not bool(refused.get("ok", false))
		and str(refused.get("reason", "")) == "player_bindings_corrupt",
		"A corrupt binding document stops the authority by name")
	root.remove_child(corrupt)
	corrupt.free()
	var unsupported_dir: String = dir.path_join("unsupported")
	DirAccess.make_dir_recursive_absolute(unsupported_dir)
	var other := FileAccess.open(unsupported_dir.path_join("player_bindings.json"),
		FileAccess.WRITE)
	other.store_string(JSON.stringify({"version": 99, "state": {"players": {}}}))
	other.close()
	var unsupported := WorldHost.new()
	unsupported.name = "Unsupported"
	root.add_child(unsupported)
	var refused_version: Dictionary = unsupported.configure(unsupported_dir, START, WORLD)
	_expect(not bool(refused_version.get("ok", false))
		and str(refused_version.get("reason", "")) == "player_bindings_unsupported",
		"An unsupported binding version is refused")
	root.remove_child(unsupported)
	unsupported.free()


static func _proof(secret_text: String) -> String:
	return PlayerBindingState.proof(secret_text, WORLD)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("PLAYER_IDENTITY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
