# RECORD-20 · 纠纷事件核验与补偿执行切片

状态：切片完成，未验收；只表示 M12-04 的权威事件核验与现金补偿执行，
不表示 M12-04 已完成。
日期：2026-11-16。

## 问题

[RECORD-17](RECORD-17-dispute-authority.md) 已把案件接到 `disputes.json` 与
RPC 23/24，但立案只是“格式合法且非空”的事件 id，`compensation` 裁定也只是
审计语义。本切片补上两件事：

- 立案引用的事件必须由权威现有日志确认真实存在，且属于当前世界；客户端
  自报、伪造或从另一个世界复制的事件编号不能立案。
- `compensation` 裁定必须真实转账：被裁定方（`against`）的可用现金转入受
  补偿方（`filed_by`），同一案件只执行一次，余额不足拒绝裁定，现金守恒、
  重放/重启不二次转账。

## 边界与语义取舍

- 案件文档 `state` 仍是严格两键形状（`authority_roles`、`cases`），没有新增
  案件字段。补偿金额不写进 `ruling`。
- 裁定命令的参数新增可选 `amount`（正整数）。它只用于 `outcome =
  compensation`；`advisor: true` 仍先返回 `advisory_only`，不要求金额。
- 被裁定方是 `against`，受补偿方是 `filed_by`。设计文档没有给出相反方向
  或其他收款方，这是本切片采用的明确默认。
- 余额不足、缺少收款账户或缺少付款账户都拒绝裁定并保持 `accepted`。不部分
  扣款、不自动开户（开户会发行新赠款）、不暗中增发。
- 其他裁定结果 `upheld` / `dismissed` / `warning` 仍是语义记录；封禁、恢复
  备份、权属更正和其他处罚形式不在本切片。
- 面板没有补偿金额输入，因此本切片没有改 `Game/ui/dispute_panel.gd`、
  `Game/scenes/main.gd` 或 RPC 形状。网络请求只是在既有 `args` 字典里多带
  一个 `amount` 键。

## A. 权威事件核验

`HeadlessWorld._file_dispute()` 先调用 `DisputeState.file()` 保留原有的
格式、非空、唯一、案件上限和权限原因，再逐个核对事件：

| 来源 | 覆盖事实 |
|---|---|
| `farm.command_result(event_id)` | 已接受并随 `farm.json` 落盘的农场/经济命令 |
| `conflicts.consumed` | 已提交交战的命令 id（`conflicts.json`） |
| 经济账本条目的 `event_id` | 更长的账本审计链（支付、交易、到期等） |

三个来源都由权威写入并属于当前 `world_id`；没有新增外部事件源、事件文档或
持久化格式。任一事件无法确认时返回 `unknown_event`，不写 `disputes.json`。
复制另一个世界真实事件的编号同样因不在本世界日志中而被拒绝。

## B. 补偿真实执行

### 现金链路

`Economy.authority_pay()` 是权威专用转账原语：校验账户存在与余额，写入一条
平衡的 `pay` 账本分录（受补偿方借记、被裁定方贷记），再移动两边的现金。
它使用保留命名空间 `dispute_compensate_<case_id>`，并把该前缀加入
`Ledger.RESERVED_EVENT_PREFIXES`，所以普通客户端命令 id 无法与补偿事件冲突。
`Economy.issued` 与现金总额都不变。

### 信封中的执行记录

`disputes.json` 信封增加 `enforcement` 字段：

```json
{
  "version": 1,
  "world_id": "...",
  "state": { "authority_roles": {...}, "cases": {...} },
  "commands": [...],
  "enforcement": {
    "<case_id>": { "amount": 30, "at_utc": 1800000000.0, "paid": true }
  }
}
```

格式评估与保留原因：

- `state` 不能新增字段：`DisputeState.valid()` 要求严格两键和严格案件键集。
- 有界命令日志（64 条）和有界账本（512 条）都会淘汰旧项，不能作为跨重启的
  永久“已付款”标记。
- `enforcement` 按案件 id 索引，最多 `MAX_CASES` 条，键集固定，加载和保存都
  校验金额、时间、`paid` 布尔值，并要求案件存在且裁定确为 `compensation`、
  时间与裁定一致。
- 旧文档没有该键时按空表读取，仍是版本 1；不需要迁移或兼容分支。

### 提交顺序与失败路径

一次补偿裁定的顺序是：

1. 案件、命令日志和 `paid=false` 记录一次原子写入 `disputes.json`；
2. 在同一权威时刻对农场候选执行平衡转账，并原子写入 `farm.json`；
3. 转账落盘后把 `paid=true` 写回 `disputes.json`。

- 第 1 步失败：不碰现金，内存仍是 `accepted`。
- 第 2 步失败：农场候选取消，回滚第 1 步；测试确认 `farm.json` 与
  `disputes.json` 都逐字节回到操作前。
- 第 3 步失败：案件与现金已经落盘。内存保留 `paid=true`，下一次成功保存补写
  标记；重启时账本事件仍在，恢复只补标记、不再转账。
- 在 1、2 之间崩溃：打开世界时看到 `paid=false` 且账本没有对应事件，按记录
  补付一次。
- 在 2、3 之间崩溃：打开世界时看到 `paid=false` 但账本已有完全匹配的事件，
  只补 `paid=true`。
- 恢复前会先核对已有账本分录的付款方、收款方和金额；不一致时停止启动
  （`recover_disputes_compensation_conflict`），不把另一笔现金移动当作补偿。

同一案件已经处于 `ruled` 后，任何新裁定命令都返回 `invalid_status`；同一
命令 id 的重放由持久命令日志返回 `duplicate`。两条路径都不会再次转账。

## 覆盖矩阵

| 要求 | 测试证据 |
|---|---|
| 真实存在的事件可以立案 | `The world records event_alpha...` + `An ordinary member files a case over the authority` |
| 从未发生的事件拒绝立案 | `A filing over an event that never happened is refused`、`...creates no disputes.json` |
| 伪造/格式合法但不存在的编号 | 同上 `unknown_event` |
| 另一个世界的事件拒绝 | `An event from another world is refused as unknown` |
| 事件核验后仍可重放立案 | `Replaying the same filing command returns the first result`、文档逐字节不变 |
| 补偿成功一次 | `The affordable compensation ruling succeeds`，双方余额 150/90 |
| 账本分录平衡且可审计 | `The compensation is a balanced pay ledger entry`、借贷方向断言 |
| 同一命令重放不转账 | `Replaying the compensation ruling returns duplicate`、两份文档逐字节不变 |
| 二次裁定拒绝 | `A second ruling on the same case is refused` |
| 重启保留余额且不二次转账 | `The compensation balances survive the restart exactly once`、`A post-restart ruling attempt moves no cash` |
| 余额不足拒绝，不部分扣款 | `An unaffordable compensation is refused instead of partially charged` |
| 缺少金额拒绝 | `A compensation ruling without an amount is refused` |
| 非管理员补偿拒绝 | `A non-authority compensation ruling is refused` |
| 缺少账户拒绝、不自动开户 | `compensation_no_account`（实现路径；测试通过余额不足夹具覆盖拒绝语义） |
| 现金守恒 | 总额与 `economy_issued()` 不变、`economy_reconcile()` 仍为真 |
| disputes 保存失败不动现金 | `A failed dispute save moves no cash`、`farm.json` 逐字节不变 |
| farm 保存失败回滚案件 | `A failed farm save rolls the dispute document back` |
| 重试只转一次 | `The retry transfers the compensation exactly once`、`The farm-save retry transfers the compensation exactly once` |
| 崩溃后打开补付一次 | `The open-time recovery pays the pending compensation once`、`...does not transfer twice` |
| 恢复后 `paid` 持久 | `The recovered compensation records a durable paid marker` |
| 访客/匿名写入拒绝 | `dispute_network_test`：访客 `forbidden`、匿名 `no_player` |

## 验证

实际运行命令：

```sh
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 420 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/dispute_authority_test.gd"

cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 600 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/dispute_network_test.gd"
```

原始末行：

```text
DISPUTE_AUTHORITY_TEST checks=177 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-authority-528583
DISPUTE_NETWORK_TEST checks=95 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-network-362214
```

面板真实网络联调（未改面板代码，只给夹具补一条真实事件）：

```text
DISPUTE_PANELS_NETWORK_TEST checks=199 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-panels-network-374700
```

回归：

```text
DISPUTE_STATE_TEST checks=183 failures=0
LEDGER_TEST checks=1841 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/ledger-29318
M4_ECONOMY_COMMANDS_TEST checks=169 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-economy-commands-562432
FARM_STATE_TEST checks=582 failures=0
```

解析检查：`--check-only --script` 无输出错误，覆盖
`Game/world/headless_world.gd`、`Game/world/disputes_store.gd`、
`Game/world/world_host.gd`、`Game/farm/economy_state.gd`、
`Game/farm/farm_state.gd`、`Game/farm/ledger_state.gd`。

## 未覆盖

- 面板补偿金额输入已在后续切片补上（见下节）；三维地图、真实处罚其他形式仍未实现。
- 真实处罚的其他形式：封禁、恢复备份、权属更正、警告期限与执行预算消耗。
- 退款/撤销补偿、更正后的反向分录、多管理员合议与并发裁定。
- 两个 sidecar 仍是分步原子写，不是跨文件事务。正常失败路径会回滚；若
  `paid=true` 的最后一次写回失败、进程继续运行并写入超过账本容量后才崩溃，
  `paid=false` 记录可能因账本事件被淘汰而无法核对。该组合没有专门夹具。
- Windows、真实跨机网络、TLS 证书轮换与长时间运行。
- 事件语义相关性（只核验事件真实存在并属于本世界，不判断事件是否证明案件
  主张）。

## 面板补偿输入（后续切片）

`Game/ui/dispute_panel.gd` 的裁定行新增 `CompensationAmount` 文本框，默认隐藏；
选择“补偿”时显示，切回其他结果时隐藏。提交前要求正整数金额：空值、非整数或
小于 1 不打开确认框，也不再发送请求；有效金额作为顶层 `amount` 与 `decision`
一起转发（只读建议模式不要求金额）。面板仍不判断账户、余额或案件状态，全部由
权威返回。确认文案明确“会从被裁定方转出补偿金额”。

验证：`DISPUTE_PANEL_TEST checks=98 failures=0`（新增 6 项断言：字段存在、
隐藏/显示、非法金额拦截、有效金额确认、金额与结果同发、切回隐藏）。

## 关联

- [M12 计划](PLAN.md) 的 M12-04 段（本记录不修改计划）。
- [RECORD-04 · 案件基础](RECORD-04-disputes.md)。
- [RECORD-17 · 执法闭环接入世界权威](RECORD-17-dispute-authority.md)。
- [RECORD-18 · 纠纷面板](RECORD-18-dispute-panel.md)。
- [RECORD-19 · 纠纷面板真实网络联调](RECORD-19-dispute-panels-network.md)。
- 实现：`Game/world/headless_world.gd`、`Game/world/disputes_store.gd`、
  `Game/world/world_host.gd`、`Game/farm/economy_state.gd`、
  `Game/farm/farm_state.gd`、`Game/farm/ledger_state.gd`。
- 测试：`tests/dispute_authority_test.gd`、`tests/dispute_network_test.gd`、
  `tests/dispute_panels_network_test.gd`。
