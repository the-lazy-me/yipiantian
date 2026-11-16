# M12-25 · 参与制度/交战的重连与离线上限切换真实网络测试（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M12 或 2.0 验收完成。前置：[RECORD-14 · 交战真实网络测试](RECORD-14-conflict-network.md)、[RECORD-10 · 参与制度真实网络测试](RECORD-10-participation-network.md)。

## 目的

既有网络夹具覆盖了交战与参与制度的主路径，但防守方的在线状态只在单进程内改变：没有经过“真人连接 → 断线 → 权威移除成员 → 同一目标再次受击 → 重连”的真实链路。缺口 G17 需要证据证明：

- 权威按连接表推导 `defender_online`，而不是按客户端载荷或历史事实；
- 同一目标+窗口的累计损失在防守方离线时使用更小的 `offline_loss_cap` 封顶；
- 离线窗口的额度用尽后，权威以具名原因拒绝，且不改任何耐久文档；
- 防守方重连后摘要与视图恢复权威状态，交战重新按在线上限结算；
- 重放离线期间发出的命令 id 不会二次结算。

## 实现

新增 `tests/conflict_offline_cap_network_test.gd`，参照 `tests/participation_network_test.gd`、`tests/conflict_network_test.gd`、`tests/resolution_network_test.gd`：

- 真实 `Game/world/world_server.gd --host-player=...`，环回空闲端口，`wss://127.0.0.1:<port>`；
- 父进程为进攻方（`PLAYER_A`，房主）的 `WorldClient`，全程保持在线；
- 防守方（`PLAYER_B`）由同一测试脚本以 `--role=defender` / `--role=reconnect` 子进程运行：一个 `SceneTree` 只有一个 `SceneMultiplayer`，同进程无法同时扮演两个成员（沿用 `m4_join_test.gd` 的角色子进程做法）；
- 子进程报告写入 `.local/verification/conflict-offline-cap-<ticks>/`，先写 `.tmp` 再改名；父进程轮询到 JSON 可解析才读取，不把“文件存在”当作就绪；
- 控制标记（同意、刷新、停止）也是同目录明文文件，所有等待都有 `Time.get_ticks_msec()` 上限；
- 真实账户/商人/招募建立双方单位，真实 RPC 17/18 声明与同意、19/20 交战、13/14 招募；
- 制度一次声明两个不重叠半开窗口：在线窗口 `[now-120, now+15)`、离线窗口 `[now+16, now+3600)`；在线上限 3、离线上限 2；
- 断言以 RPC 答复的 `state`、`participation.json` 的耐久交战行与 `conflicts.json` 的 outcome 三方交叉核对；重放时对 farm/units/participation/conflicts 做逐字节比较。

时间线：

1. A 开户、开商人、买 14 份 greens、招募 4 人单位；B 子进程开户、买 1 份 greens、招募 1 人单位并报告就绪；
2. 房主声明制度并自任 attacker；B 在线同意 defender；
3. 在线窗口第一次交战：投入 4 人，损失 3（在线上限），`defender_online=true`，单位 4→1；
4. B 子进程按停止标记退出；父进程等待权威名册移除 `PLAYER_B`（不是仅等进程退出）；
5. 招募第二个 2 人单位；等权威时钟进入离线窗口；
6. 同一目标第二次交战（离线）：投入 3 人，损失 2（离线上限），`defender_online=false`，目标累计 5；参与文档 `cap=2`、`window_id=offline-window`；
7. 同一目标同一窗口第三次离线交战：拒绝 `target_cap` 且 `reason_text` 非空，四类文档字节不变，不生成交战行；
8. B 子进程重连：摘要携带权威现金 106，冲突视图恢复目标累计 5，并保留离线结算的 `defender_online=false`；
9. 重连后第三次交战（在线，同一离线窗口）：在线上限 3 减去已用 2，只允许损失 1，`defender_online=true`，目标累计 6；重连客户端刷新后看到在线结算；
10. 重放第 6 步的命令 id：`duplicate`，四类文档字节不变，目标仍为 6，现金/物资不二次变化。

## 覆盖

| 范围 | 断言 |
|---|---|
| 启动/停止 | `server-status.json` 的 running/port/opened=created/world/host_player；停止后 `stopped` + `save=saved` |
| 线上限 | 4 兵对同一目标损失 3；答复 `defender_online=true`、`window_id=online-window`、`target_lost_after=3`；单位 4→1；四类耐久文档与参与行 `cap=3` 一致 |
| 断线识别 | B 子进程退出后，权威名册移除 `PLAYER_B`；离线交战答复 `defender_online=false` |
| 离线上限 | 同一目标、第二窗口投入 3 兵只损失 2；参与行 `cap=2`、`window_id=offline-window`；`conflicts.json` 记录 `defender_online=false`、`participation_cap=2`、`losses=2` |
| 共享目标预算 | 目标累计 3→5→6，`target_cap=100` 在在线/离线窗口之间保持同一行 |
| 具名拒绝 | 离线窗口额度用尽后拒绝 `target_cap`，`reason_text` 非空，farm/units/participation/conflicts 字节不变，不生成交战行 |
| 重连摘要 | 重连子进程的摘要现金 106、角色 member、目标累计 5；视图保留离线 outcome 的 `defender_online=false` |
| 上限切回 | 重连后同一目标再次交战按在线上限只损失 1，`defender_online=true`；参与行 `cap=3`、`loss_total_after=3`；重连客户端刷新后看到该在线结算 |
| 幂等 | 重放离线期间的命令 id 返回 `duplicate`；四类文档字节不变；视图仍只有三条已结算命令，目标仍为 6；现金 12/105、物资 0 不二次变化 |

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 240 "$GODOT" --headless --path Game \
  --script "$PWD/tests/conflict_offline_cap_network_test.gd"
```

原始末行（连续两次完整运行）：

```text
CONFLICT_OFFLINE_CAP_NETWORK_TEST checks=117 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/conflict-offline-cap-376661
CONFLICT_OFFLINE_CAP_NETWORK_TEST checks=117 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/conflict-offline-cap-376863
```

回归：

```text
NON_PARTICIPATION_EXPERIENCE_TEST checks=156 failures=0
CONFLICT_NETWORK_TEST checks=117 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/conflict-network-381824
FONT_COVERAGE_TEST checks=1272 failures=0 missing=0
```

## 缺陷

未发现生产缺陷，未修改 `Game/world/world_host.gd` 或其它生产文件。权威已经按 `_player_peer(defender) != 0` 从成员表推导 `defender_online`，断开时 `_forget` 移除成员并广播名册；离线上限由 `Participation.engage` 选择 `offline_loss_cap`；同一 `target+window` 的累计账本在在线/离线之间共享，因此重连后在线上限只补齐剩余额度。

## 未覆盖

- Windows 实机网络运行与子进程 shell 日志；状态文件断言跨平台保留。
- 网络回复仍不携带完整 `outcome`；上限切换断言依赖 `state.recent`、`participation.json` 与 `conflicts.json` 三方核对。
- 非优雅断线（进程被强杀、网络中断）只覆盖到“子进程正常退出”；强杀后权威识别延迟与重连退避不在本切片内。
- 防守方离线期间由其它进攻者重复攻击同一目标、多个防守方同时切换在线状态不在本切片内。
- 交战 UI 联调、延迟/丢包与跨引擎协议兼容不在本切片内。

## 关联

- 交战网络：[RECORD-14 · 交战真实网络测试](RECORD-14-conflict-network.md)。
- 参与制度网络：[RECORD-10 · 参与制度真实网络测试](RECORD-10-participation-network.md)。
- 离线战损：[RECORD-23 · 防守方战损](RECORD-23-defender-loss.md)。
- 阶段计划：[M12 PLAN](PLAN.md)。
