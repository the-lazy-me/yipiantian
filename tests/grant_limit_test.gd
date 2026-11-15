extends SceneTree
## R16 赠款半边：开户赠款按“成员”发行，而不是按客户端每次声明的 `player_id`。
##
## ADR-029 之后，一个安装的 `player.key` 会在 `player_bindings.json` 里把多个
## `player_id` 绑到同一个世界作用域证明。权威用这份文档作为“同一成员”的证据：
## 同一证明的另一个 id 已经持有一次性 `granted` 标记时，新 id 的开户命令在规则
## 之前被拒绝。没有网络；这里直接驱动权威命令路径（与 `execute_for_member`
## 收到的相同结构），并重开世界验证拒绝跨重启保持。
##
## 真实 WSS 会话里的同一邀请换 id 用例见 `tests/m4_economy_commands_test.gd`。

const WorldHost = preload("res://world/world_host.gd")
const PlayerBindingState = preload("res://world/player_binding_state.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const Economy = preload("res://farm/economy_state.gd")

const START: float = 1800000000.0
const WORLD: String = "world-grant-limit"
## 32 字节安装凭据的 base64。A 与 ALIAS 共用同一个，B 用另一个。
const SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtOTk="
const ALICE: String = "player_grant_00000000000000000000000001"
const ALIAS: String = "player_grant_00000000000000000000000002"
const BOB: String = "player_grant_00000000000000000000000003"

var checks: int = 0
var failures: Array[String] = []
var dir: String = ""
var host: WorldHost
var world_dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir() \
		.path_join(".local/verification/grant-limit-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	world_dir = dir.path_join("world")
	host = _open_host("Authority")
	if host == null:
		_finish()
		return
	_test_first_issuance()
	_test_alias_refused()
	_test_other_member_allowed()
	_test_reconnect_and_replay()
	_test_restart_keeps_refusal()
	print("GRANT_LIMIT_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), dir])
	_finish()


func _open_host(node_name: String) -> WorldHost:
	var opened_host := WorldHost.new()
	opened_host.name = node_name
	root.add_child(opened_host)
	var opened: Dictionary = opened_host.configure(world_dir, START, WORLD)
	if not bool(opened.get("ok", false)):
		_expect(false, "The authority opens: " + str(opened.get("reason", "")))
		return null
	# This unit test has no transport behind its emulated peers. Economy commits
	# emit shared_changed, whose broadcast would address a nonexistent peer; the
	# command path itself is what this test exercises.
	var changed: Signal = opened_host.world.shared_changed
	if changed.is_connected(opened_host._broadcast_summary):
		changed.disconnect(opened_host._broadcast_summary)
	return opened_host


## Models the join side effects for one peer: the identity gate runs first (it
## binds the presented proof on first use), then the peer becomes a member and
## its player id is recorded exactly as `join()` does.
func _join(target: WorldHost, peer: int, player_id: String, secret: String) -> void:
	var verified: Dictionary = target._verify_player(
		player_id, PlayerBindingState.proof(secret, WORLD))
	_expect(bool(verified.get("ok", false)), "The identity gate admits " + player_id)
	target._members[peer] = WorldInvite.MEMBER
	target._players[peer] = {"id": player_id, "name": player_id}


func _open_account(target: WorldHost, peer: int, command_id: String) -> Dictionary:
	# Only the acting peer is present, so a commit does not try to broadcast to
	# emulated peers that have no transport behind them.
	target._members.clear()
	target._members[peer] = WorldInvite.MEMBER
	return target.execute_for_member(peer, FarmCommand.make_account_open(command_id, START))


func _issued(target: WorldHost) -> int:
	return target.world.farm.economy_issued()


func _test_first_issuance() -> void:
	_join(host, 1, ALICE, SECRET_A)
	var opened: Dictionary = _open_account(host, 1, "grant-open-alice")
	_expect(bool(opened.get("ok", false)) and not bool(opened.get("duplicate", true)),
		"The member's first account opens normally")
	_expect(host.world.farm.economy_cash(ALICE) == Economy.OPENING_GRANT
		and host.world.farm.economy_granted(ALICE),
		"The first issuance pays the full opening grant once")
	_expect(_issued(host) == Economy.OPENING_GRANT,
		"Only the first issuance is on the issued total")


func _test_alias_refused() -> void:
	# Same installation credential, new player id: the binding gate binds it,
	# so the authority can see both ids belong to one member.
	_join(host, 2, ALIAS, SECRET_A)
	var issued_before: int = _issued(host)
	var refused: Dictionary = _open_account(host, 2, "grant-open-alias")
	_expect(not bool(refused.get("ok", false))
		and str(refused.get("reason", "")) == "grant_already_issued",
		"A second id bound to the same proof cannot mint a second grant")
	_expect(not str(refused.get("reason_text", "")).is_empty(),
		"The refusal carries a player-visible reason")
	_expect(host.world.farm.economy_cash(ALIAS) == 0
		and not host.world.farm.economy_granted(ALIAS),
		"The alias received no cash and no durable grant marker")
	_expect(_issued(host) == issued_before,
		"A refused alias issuance changes no issued total")
	_expect(host.world.farm.economy_total_cash() == issued_before,
		"A refused alias issuance changes no account total")
	# A new id string is not a way around the limit either: the same proof is
	# still represented by the granted sibling.
	var other_alias: String = "player_grant_00000000000000000000000004"
	_join(host, 3, other_alias, SECRET_A)
	var refused_again: Dictionary = _open_account(host, 3, "grant-open-alias-2")
	_expect(not bool(refused_again.get("ok", false))
		and str(refused_again.get("reason", "")) == "grant_already_issued",
		"Another id with the same proof is refused as well")


func _test_other_member_allowed() -> void:
	_join(host, 4, BOB, SECRET_B)
	var opened: Dictionary = _open_account(host, 4, "grant-open-bob")
	_expect(bool(opened.get("ok", false)),
		"A different installation credential is a different member")
	_expect(host.world.farm.economy_cash(BOB) == Economy.OPENING_GRANT
		and _issued(host) == Economy.OPENING_GRANT * 2,
		"The second distinct member gets the same one-time grant")


func _test_reconnect_and_replay() -> void:
	# A reconnect is a new peer with the same id. Its own id's grant is decided
	# by the economy rule, not by the cross-id gate.
	_join(host, 5, ALICE, SECRET_A)
	var again: Dictionary = _open_account(host, 5, "grant-open-alice-new")
	_expect(not bool(again.get("ok", false))
		and str(again.get("reason", "")) == "already_granted",
		"Reconnecting under the same id cannot grant twice")
	var accepted: Dictionary = host.world.farm.snapshot()
	var replay: Dictionary = _open_account(host, 5, "grant-open-alice")
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"The committed grant id still replays after reconnect")
	_expect(host.world.farm.snapshot() == accepted,
		"The replay changes no farm state")


func _test_restart_keeps_refusal() -> void:
	# Reopen the same directory: both bindings and the granted marker are durable.
	root.remove_child(host)
	host.free()
	host = _open_host("Reopened")
	if host == null:
		return
	_join(host, 6, ALIAS, SECRET_A)
	var refused: Dictionary = _open_account(host, 6, "grant-open-alias-after-restart")
	_expect(not bool(refused.get("ok", false))
		and str(refused.get("reason", "")) == "grant_already_issued",
		"The alias is still refused after a restart")
	_join(host, 7, BOB, SECRET_B)
	var bob_again: Dictionary = _open_account(host, 7, "grant-open-bob-new")
	_expect(not bool(bob_again.get("ok", false))
		and str(bob_again.get("reason", "")) == "already_granted",
		"The distinct member's own account stays single after a restart")
	_expect(_issued(host) == Economy.OPENING_GRANT * 2,
		"Restart reissues no opening grant")


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)
