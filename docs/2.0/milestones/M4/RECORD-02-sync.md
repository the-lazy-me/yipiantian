# M4-03 · 同步与重连（并发与幂等）

执行日期：2026-11-15。状态：切片完成，不表示 M4 或 M4-03 验收完成。前置：[M4-02 创建与加入](RECORD-01-join.md)。

## 实现

在 M4-02 的宿主/成员之上补齐两件事：

- **同一地块的并发裁决**：两个成员同时提交对同一成熟地块的收获。种子按顺序进入权威循环，先到者提交成功，后到者被规则以 `empty` 拒绝；落盘库存只增加 1，事件序号只前进 1。
- **重连幂等**：成员以新的 peer 重新加入后重试已提交过的命令 id。宿主从 `FarmState` 的事务账本读出原结果，返回 `duplicate=true` 与 `stage=duplicate`，不二次发奖、不推进序号。
- **事件尾部补齐**（第二轮）：宿主保留最近 `TAIL_LIMIT = 256` 条提交的尾部（序号、命令、结果）。成员可请求“自序号 N 之后的所有提交”；尾部还完整时按序返回，已经滚出保留窗口时返回 `tail_expired`，让客户端改拉快照而不是接受一个缺口。重复回放不进入尾部——重连成员不能把同一变更当成新事件应用两次。
- **在线成员同步**（第二轮）：一次提交除回复提交者外，还会以同一回复通道推送给其他成员。客户端按序号去重：`sequence <= last_sequence` 的推送直接丢弃，因此重复投递不会重复记账，旧发送者也不能把客户端拉回旧状态。
- 成员侧收到序号回退的回复时视为权威丢失（`stale_sequence`），不会把旧权威的结果当成当前状态。
- **命令前置条件**（第三轮）：成员提交时附带 `based_on_sequence`（它据以做决定的世界序号）。宿主在应用前比较；不一致返回 `stale_precondition` 并带上 `expected_sequence` 与实际序号，让客户端知道该重读哪一版。已提交 id 的重试豁免此检查，否则重放就不再幂等。
  - 这条补上了“规则仍然会接受、但决定所依据的状态已经变了”的空档：例如两人在同一成熟地块收获，败者现在得到 `stale_precondition` 而不是只能靠规则以 `empty` 拒绝。
  - 缺少该字段一律拒绝（`missing_precondition`），不退化成“没有前置条件也照做”。
- **完整快照**（第四轮）：`summary` 回复除展示用视图外，附带 `snapshot` 文档——`{now_utc, farm, decorations}`，与 `FarmStore` 落盘的两份快照同形。因此尾部滚出窗口、或成员首次加入时，恢复的不只是地块视图，而是布局、厨房、动物、记忆、季节与摆设。成员侧 `restore_state()` 用与磁盘加载完全相同的校验器重建 `FarmState`/`Decorations`，损坏或被截断的文档返回具名原因，不会半应用。

## 验证

`tests/m4_sync_test.gd`：一个真实宿主进程 + 四个真实成员进程（回环 WSS、自签证书、隔离目录 `.local/verification/m4-sync-*`）。先启动一个只连接不提交的“旁观成员”，再同时启动两个竞争成员，最后启动一次重连成员。

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 280 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_sync_test.gd"
```

结果：`M4_SYNC_TEST checks=39 failures=0`（第三轮加入前置条件后，本机连续复跑 2 次通过）。尾部规则由 `WORLD_TAIL_TEST checks=27 failures=0` 独立覆盖；快照完整性由 `WORLD_SNAPSHOT_TEST checks=28 failures=0` 覆盖，`M4_JOIN_TEST checks=54`（第四轮）在真实 WSS 会话上验证成员能从摘要恢复完整世界。

| 用例 | 实际输出 | 结果 |
|---|---|---|
| 并发收获 | 胜者 `ok=true, stage=committed, reward_amount=1`；败者 `ok=false, reason=stale_precondition, expected_sequence=0, sequence=1`；两者都看到序号 1 | 通过 |
| 前置条件判定 | 败者据以提交的序号是 0，权威已是 1，因此不是笼统失败而是“你基于旧状态” | 通过 |
| 规则仍独立生效 | 之后再加入的成员基于当前序号提交，被规则以 `empty` 拒绝 | 通过 |
| 在线广播 | 旁观成员未提交任何命令，却收到 1 条 `sequence=1` 的变更，`last_sequence` 随之变为 1 | 通过 |
| 重连重试 | 新 peer 加入后返回 `duplicate=true, ok=true, sequence=1`（前置条件豁免） | 通过 |
| 不重复发奖 | 落盘 `inventory.greens=1`、`harvested.greens=1` | 通过 |
| 单条事件 | 宿主汇总 `commands=1`，落盘 `transaction.sequence=1` | 通过 |
| 加入次数 | 5 次（旁观、两个竞争者、规则检查、一次返回） | 通过 |
| 快照恢复 | 成员从 `summary.snapshot` 重建 `FarmState`/`Decorations`，与宿主落盘快照逐字段相等；空/缺字段/篡改文档分别返回 `no_snapshot`、`invalid_farm`、`invalid_decorations`、`invalid_time` | 通过 |

尾部补齐的独立用例（`WORLD_TAIL_TEST`）覆盖：空尾、请求点在尾部内、恰好在保留窗口边界、滚出窗口后返回 `tail_expired`、未来序号被拒、重复回放不入尾、成员端对补齐与广播都按序号去重、失败补齐不推进本地序号。

用例已加入 `.github/workflows/rule-tests.yml`。首次 CI（运行 `43633387624`，提交 `990384f`）在两平台都失败，原因是测试断言写死了“`race-a` 获胜”，而实际先后顺序取决于进程调度；产品侧裁决本身正确（一成一败）。断言已改为跟随胜者，不再假设顺序。

断言修正后的双平台绿色证据：CI 运行 `43633628528`（提交 `867d0a8`）与 `43638240059`（提交 `036e2fe`，含 `world_snapshot_test` 与第四轮断言），`rules (macos-latest)` 与 `rules (windows-latest)` 均通过。第三轮前置条件（提交 `c888220`）的双平台绿色证据为 CI 运行 `43637616958`。

## 未覆盖

- “同时”是进程级并发，不是毫秒级同步；两条命令仍按到达顺序处理。种子内的规则是确定性的，因此结果可重复，但没有测真实网络抖动或乱序到达。
- 前置条件以“世界序号”为单位，粒度是整个世界而不是单个地块或建筑：序号一致就放行，因此“中间发生过一件与目标无关的事”不会阻止命令。需要按目标细化时，还要引入地块版本。
- 事件尾只存在于宿主内存，重启即清空；重启前离开的成员一律只能拉快照。尾部上限 256 条，且只按序号补齐，不含“补齐失败后自动重拉快照”的完整客户端流程（成员只发出 `request_summary`）。
- 广播按提交顺序发送，但没有测高并发下的重排、丢包或慢消费者；成员只处理序号，不校对命令内容与本地状态的一致性。
- 摘要附带的快照是整世界文档，没有增量差量；大世界下每次重连都传完整状态（当前默认世界约 17 KB，未测更大布局）。成员侧只重建出 `FarmState`/`Decorations`；第五轮起主场景已通过 `world_client.gd` 接入权威世界（见 [RECORD-06](RECORD-06-client.md)）。
- 未覆盖断线期间客户端离线排队与离线收益；`authority_lost` 现在会在主场景显示一行原因并停在最后确认状态，但没有自动重连或恢复流程。
- 未测同一世界多个会员同时加入时的认证顺序压力、`auth_timeout` 边界或恶意重复提交。
- 没有跨机器、Windows 手工验证（CI 会跑同一用例）；没有测真实局域网延迟与丢包。

## 关联

- 前序：[M4-02 创建与加入](RECORD-01-join.md)；传输裁决 [ADR-004](../decisions/ADR-004-transport.md)。
- 事务账本与幂等窗口：[M3-03](../M3/RECORD-03-commit-recovery.md)。
- 阶段计划：[M4 PLAN](PLAN.md) M4-03。
