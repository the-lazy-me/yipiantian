# M4-03 · 同步与重连（并发与幂等）

执行日期：2026-11-15。状态：切片完成，不表示 M4 或 M4-03 验收完成。前置：[M4-02 创建与加入](RECORD-01-join.md)。

## 实现

在 M4-02 的宿主/成员之上补齐两件事：

- **同一地块的并发裁决**：两个成员同时提交对同一成熟地块的收获。种子按顺序进入权威循环，先到者提交成功，后到者被规则以 `empty` 拒绝；落盘库存只增加 1，事件序号只前进 1。
- **重连幂等**：成员以新的 peer 重新加入后重试已提交过的命令 id。宿主从 `FarmState` 的事务账本读出原结果，返回 `duplicate=true` 与 `stage=duplicate`，不二次发奖、不推进序号。
- **事件尾部补齐**（第二轮）：宿主保留最近 `TAIL_LIMIT = 256` 条提交的尾部（序号、命令、结果）。成员可请求“自序号 N 之后的所有提交”；尾部还完整时按序返回，已经滚出保留窗口时返回 `tail_expired`，让客户端改拉快照而不是接受一个缺口。重复回放不进入尾部——重连成员不能把同一变更当成新事件应用两次。
- **在线成员同步**（第二轮）：一次提交除回复提交者外，还会以同一回复通道推送给其他成员。客户端按序号去重：`sequence <= last_sequence` 的推送直接丢弃，因此重复投递不会重复记账，旧发送者也不能把客户端拉回旧状态。
- 成员侧收到序号回退的回复时视为权威丢失（`stale_sequence`），不会把旧权威的结果当成当前状态。

## 验证

`tests/m4_sync_test.gd`：一个真实宿主进程 + 四个真实成员进程（回环 WSS、自签证书、隔离目录 `.local/verification/m4-sync-*`）。先启动一个只连接不提交的“旁观成员”，再同时启动两个竞争成员，最后启动一次重连成员。

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 280 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_sync_test.gd"
```

结果：`M4_SYNC_TEST checks=35 failures=0`（第二轮加入旁观成员后）。尾部规则由 `WORLD_TAIL_TEST checks=27 failures=0` 独立覆盖。

| 用例 | 实际输出 | 结果 |
|---|---|---|
| 并发收获 | 一个 `ok=true, stage=committed, reward_amount=1`，另一个 `ok=false, reason=empty`，两者 `sequence=1` | 通过 |
| 唯一胜者 | 两者 `ok` 互斥，失败原因来自规则而不是静默写入 | 通过 |
| 序号一致 | 两个成员都看到序号 1 | 通过 |
| 在线广播 | 旁观成员未提交任何命令，却收到 1 条 `sequence=1` 的变更，`last_sequence` 随之变为 1 | 通过 |
| 重连重试 | 新 peer 加入后返回 `duplicate=true, ok=true, sequence=1` | 通过 |
| 不重复发奖 | 落盘 `inventory.greens=1`、`harvested.greens=1` | 通过 |
| 单条事件 | 宿主汇总 `commands=1`，落盘 `transaction.sequence=1` | 通过 |
| 加入次数 | 4 次（旁观、两个竞争者、一次返回） | 通过 |

尾部补齐的独立用例（`WORLD_TAIL_TEST`）覆盖：空尾、请求点在尾部内、恰好在保留窗口边界、滚出窗口后返回 `tail_expired`、未来序号被拒、重复回放不入尾、成员端对补齐与广播都按序号去重、失败补齐不推进本地序号。

用例已加入 `.github/workflows/rule-tests.yml`。首次 CI（运行 `43633387624`，提交 `990384f`）在两平台都失败，原因是测试断言写死了“`race-a` 获胜”，而实际先后顺序取决于进程调度；产品侧裁决本身正确（一成一败）。断言已改为跟随胜者，不再假设顺序。

断言修正后的双平台绿色证据：CI 运行 `43633628528`（提交 `867d0a8`），`rules (macos-latest)` 与 `rules (windows-latest)` 均通过。

## 未覆盖

- “同时”是进程级并发，不是毫秒级同步；两条命令仍按到达顺序处理。种子内的规则是确定性的，因此结果可重复，但没有测真实网络抖动或乱序到达。
- 只用规则状态（`empty`）裁决冲突，没有版本号/前置条件字段；当一个动作依赖“我读到的版本”而不是当前状态时，需要额外的前置条件比较，尚未设计。
- 事件尾只存在于宿主内存，重启即清空；重启前离开的成员一律只能拉快照。尾部上限 256 条，且只按序号补齐，不含“补齐失败后自动重拉快照”的完整客户端流程（成员只发出 `request_summary`）。
- 广播按提交顺序发送，但没有测高并发下的重排、丢包或慢消费者；成员只处理序号，不校对命令内容与本地状态的一致性。
- 快照本身仍不完整：`summary()` 有田块与库存，但缺 `layout`、`kitchen`、`animals`、`memories`、`season`、decorations。因此“拉快照”目前只能恢复地块视图。
- 未覆盖断线期间客户端离线排队、离线收益、或 `authority_lost` 之后的 UI 提示（客户端节点只发信号）。
- 未测同一世界多个会员同时加入时的认证顺序压力、`auth_timeout` 边界或恶意重复提交。
- 没有跨机器、Windows 手工验证（CI 会跑同一用例）；没有测真实局域网延迟与丢包。

## 关联

- 前序：[M4-02 创建与加入](RECORD-01-join.md)；传输裁决 [ADR-004](../decisions/ADR-004-transport.md)。
- 事务账本与幂等窗口：[M3-03](../M3/RECORD-03-commit-recovery.md)。
- 阶段计划：[M4 PLAN](PLAN.md) M4-03。
