# M4-03 · 同步与重连（并发与幂等）

执行日期：2026-11-15。状态：切片完成，不表示 M4 或 M4-03 验收完成。前置：[M4-02 创建与加入](RECORD-01-join.md)。

## 实现

在 M4-02 的宿主/成员之上补齐两件事：

- **同一地块的并发裁决**：两个成员同时提交对同一成熟地块的收获。种子按顺序进入权威循环，先到者提交成功，后到者被规则以 `empty` 拒绝；落盘库存只增加 1，事件序号只前进 1。
- **重连幂等**：成员以新的 peer 重新加入后重试已提交过的命令 id。宿主从 `FarmState` 的事务账本读出原结果，返回 `duplicate=true` 与 `stage=duplicate`，不二次发奖、不推进序号。
- 成员侧收到序号回退的回复时视为权威丢失（`stale_sequence`），不会把旧权威的结果当成当前状态。

## 验证

`tests/m4_sync_test.gd`：一个真实宿主进程 + 三个真实成员进程（回环 WSS、自签证书、隔离目录 `.local/verification/m4-sync-*`）。两个竞争成员先同时启动、再各自收集报告，确保命令真正重叠而不是轮流执行。

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 280 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_sync_test.gd"
```

结果：`M4_SYNC_TEST checks=25 failures=0`。

| 用例 | 实际输出 | 结果 |
|---|---|---|
| 并发收获 A | `ok=true, stage=committed, reward_amount=1, sequence=1` | 通过 |
| 并发收获 B | `ok=false, reason=empty, sequence=1` | 通过 |
| 唯一胜者 | 两者 `ok` 互斥，失败原因来自规则而不是静默写入 | 通过 |
| 序号一致 | 两个成员都看到序号 1 | 通过 |
| 重连重试 | 新 peer 加入后返回 `duplicate=true, ok=true, sequence=1` | 通过 |
| 不重复发奖 | 落盘 `inventory.greens=1`、`harvested.greens=1` | 通过 |
| 单条事件 | 宿主汇总 `commands=1`，落盘 `transaction.sequence=1` | 通过 |
| 加入次数 | 3 次（两个竞争者 + 一次返回） | 通过 |

用例已加入 `.github/workflows/rule-tests.yml`。

## 未覆盖

- “同时”是进程级并发，不是毫秒级同步；两条命令仍按到达顺序处理。种子内的规则是确定性的，因此结果可重复，但没有测真实网络抖动或乱序到达。
- 只用规则状态（`empty`）裁决冲突，没有版本号/前置条件字段；当一个动作依赖“我读到的版本”而不是当前状态时，需要额外的前置条件比较，尚未设计。
- 重连只覆盖“客户端进程重启”。没有覆盖长断线期间超过 64 条命令、事件尾部补齐或快照重拉（账本上限仍是 `MAX_COMMAND_RESULTS=64`）。
- 未覆盖断线期间客户端离线排队、离线收益、或 `authority_lost` 之后的 UI 提示（客户端节点只发信号）。
- 未测同一世界多个会员同时加入时的认证顺序压力、`auth_timeout` 边界或恶意重复提交。
- 没有跨机器、Windows 手工验证（CI 会跑同一用例）；没有测真实局域网延迟与丢包。

## 关联

- 前序：[M4-02 创建与加入](RECORD-01-join.md)；传输裁决 [ADR-004](../decisions/ADR-004-transport.md)。
- 事务账本与幂等窗口：[M3-03](../M3/RECORD-03-commit-recovery.md)。
- 阶段计划：[M4 PLAN](PLAN.md) M4-03。
