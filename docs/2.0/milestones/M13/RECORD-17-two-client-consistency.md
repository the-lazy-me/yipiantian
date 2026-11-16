# M13-17 · 双客户端并发一致性（真实 WSS）

日期：2026-11-16。状态：**本机真实 WSS 切片完成，未验收**。本记录只报告
`tests/two_client_consistency_test.gd` 的完整运行，不表示 M13-01 或 M13 完成；
Windows、真实跨机、断线/重连竞态与 TCC/点击均未覆盖。

范围：一个真实 `Game/world/world_server.gd` 在回环地址上以 WSS 提供服务，两个具名成员
与一个具名访客各运行在**独立的 Godot 进程**里，每个进程只挂一个真实 `WorldClient`，
由父进程通过文件协议编排。两个客户端不能共进程，因为 `WorldClient` 把会话节点固定挂
在 `/root/WorldSession`，而 `SceneMultiplayer` 每个 `SceneTree` 只有一个 peer；两个
进程才等于“两个客户端同时在线”。

只新增本测试与本记录，未修改任何产品代码、既有测试、`rules/`、`.github/` 或 workflow，
未 dispatch CI。首次运行失败的 8 项均为测试自身的取值/比较问题（`_status_outcome`
丢了 refresh 动作的 `refreshed` 字段；客户端摘要经 JSON 回读后数字为浮点，直接与权威
整数拼 JSON 比较），修正测试后连跑两次通过；**未发现需要修复的产品缺陷**。

前置：[M13 PLAN](PLAN.md)（M13-01）、[RECORD-16 摘要块消费](RECORD-16-summary-block-consumers.md)、
[ADR-027 摘要可见性](../../decisions/ADR-027-summary-visibility.md)、既有真实网络测试
`tests/panels_network_integration_test.gd`、`tests/dispute_compensation_network_test.gd`。

## 覆盖矩阵

| # | 要求 | 测试执行 | 关键断言与实测 |
|---|---|---|---|
| 1 | A 提交产生广播，B 不主动刷新即收到，随后刷新得到同一权威状态 | A 提交 `open_account`（第 1 个事件）；B 只发 `status` 观察，不请求摘要；之后 B 显式 `request_summary()` 刷新 | B 的 `state_ready` 从 1 升到 2 且**恰好 +1**，`last_sequence == 1`，`changed_sequences` 为空（经济提交不再作为第二次 `change` 投递）；B 刷新后 sequence/`committed_sequence` 仍为 1；B 再开户成为第 2 个事件；双方各 120 COIN，`total == issued == 240`，账本对账通过 |
| 2 | 双方并发提交同一实体：恰好一个成功，另一个具名拒绝/`duplicate`，现金与资产守恒、不双花 | A/B/访客三个进程先写 `.armed`，父进程写共享 `race.go` 后同时提交**同一订单 id** `two-client-race-order`（买 2 青菜 @30，托管 60） | 成员中恰好一个 `ok=true, duplicate=false`；另一个为 `ok=false, duplicate=true, reason=command_conflict` 且带权威 `reason_text`；访客被 `forbidden` 拒绝；权威上**恰好 1 行订单、1 条 `escrow_hold` 分录（借/贷各 60）**；仅赢家余额 120→60，输家仍 120；`issued=240`、`total=240`、对账通过；赢家答复的 `sequence` 与权威一致；访客无账户 |
| 3 | 两客户端交错刷新，视图序列/摘要单调一致，A 的提交不在 B 连接上重复投递 | 两轮 A→B 交替显式刷新，无新提交 | 每轮 `refreshed=true` 且 `state_ready` 各 +1；sequence 从不后退；双方同轮 sequence 相等，公开摘要（`committed_commands`、订单行、组织、基金）逐项一致；双方视图的订单/sequence/`committed_commands` 与从 `farm.json` 恢复的权威一致；`changed_sequences` 无重复，`ready_sequences` 单调不降 |
| 4 | 重启权威，两客户端重连后状态不变；重发已提交命令返回 `duplicate` 且不二次结算 | 优雅停止 → 同端口、逻辑时钟 +60s 重启 → A/B/访客自动重连 → 赢家重发同一已提交订单 | 三进程均 `reconnected>=1` 且重新 `joined`，重连摘要被应用；现金、发行量、订单、账本、sequence、`committed_commands` 与重启前逐项相同；双方重连视图与权威订单一致，未新增订单行；重放返回 `ok=true, duplicate=true, reason=""`；sequence 不变、经济状态不变、无第二条托管分录/订单行，`farm.json` **逐字节相同** |
| 5 | 访客/只读连接并发提交被拒，且不影响两名成员状态 | 访客参与第 2 项的同订单并发；重启后再刷新到最新 basis，再提交一笔新订单 `two-client-visitor-follow-up` | 并发时返回 `forbidden`；刷新后新 basis 下再次返回 `forbidden` 且带 `reason_text`；两次拒绝前后成员现金/发行量/订单/账本不变，`farm.json` 逐字节不变，无该订单或对应分录，访客仍无账户/发行 |

夹具与命令均取自现有测试已证明稳定的路径：`open_account` 与 `market_place` 由
`FarmCommand` 构造，经真实 `WorldHost.execute_for_member` 的角色门与前置条件；访客
权限来自真实邀请码；重启、同端口、`stop` 标记和 `server-status.json` 沿用
`dispute_compensation_network_test.gd` 的做法。

## 固定夹具

| 项 | 值 |
|---|---|
| 引擎 | `Godot 4.7.2.stable.official.ed1daf0bf` |
| 仓库 HEAD | `7c5f7c24ffa73080fcfbe1048f84f229ebb9a512`（运行前后不变） |
| 工作树 | 本切片只新增 `tests/two_client_consistency_test.gd`；运行前已有其他未提交改动（`Game/scenes/startup.gd`、`Game/world/world_hosting.gd`、`Game/world/world_server.gd`、`tests/invite_rotation_test.gd`），本切片未触碰 |
| 世界 / 世界 id | `world-two-client-consistency` |
| 起点 | `START = 1800000000.0` |
| 房主 | `PLAYER_A`（`player_..._201`，显示名“并发甲”） |
| 成员 | A、B（各一次性 120 COIN 开户发行） |
| 访客 | `PLAYER_V`（显示名“旁听者”，仅 `water`/`weed` 权限） |
| 并发实体 | 订单 `two-client-race-order`：`buy` / `greens` / 价 30 / 量 2 / 托管 60 / 有效期 86400s |
| 重启 | 同端口、同数据目录、逻辑时钟前移 60s |
| 产物 | `.local/verification/two-client-consistency-<ticks>/`（`world/`、各客户端 `ready/report`） |

## 实际原始输出

运行命令（仓库根目录）：

```bash
perl -e 'alarm shift; exec @ARGV' 300 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/two_client_consistency_test.gd"
```

连续两次运行的末行（目录名来自各自运行的 ticks，故不同）：

```text
TWO_CLIENT_CONSISTENCY_TEST checks=125 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/two-client-consistency-360761
TWO_CLIENT_CONSISTENCY_TEST checks=125 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/two-client-consistency-385838
```

## 未覆盖

1. **Windows。** 只在 macOS 本机运行；测试中虽有 Windows 的进程启动分支，但未在
   Windows 上执行，日志就绪检查在 Windows 下被跳过。
2. **真实跨机与真实网络条件。** 客户端和服务端都在同一台机器、回环地址，没有跨机器、
   丢包、延迟抖动、NAT/防火墙或证书主机名差异。
3. **断线/重连竞态。** 只在优雅停止后重启；没有在提交途中拔线、半开连接、重连风暴、
   两个客户端先后重连时再次并发提交，也没有覆盖重连期间的命令重试与重复窗口。
4. **TCC/点击与界面呈现。** 全程无头、无 UI、无 macOS 权限弹窗，不验证面板显示、
   点击路径或屏幕共享授权。
5. **长时间驻留。** 无 soak；只覆盖单次广播、一次并发竞争、两轮刷新和一次重启。

## 关联

- [M13 PLAN](PLAN.md) M13-01 跨系统整合。
- 摘要投影与可见性：[ADR-027](../../decisions/ADR-027-summary-visibility.md)。
- 既有真实 WSS 测试：`tests/panels_network_integration_test.gd`、
  `tests/dispute_compensation_network_test.gd`。
