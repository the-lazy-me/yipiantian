# RECORD-21 · 纠纷补偿面板真实网络联调切片

状态：切片完成，未验收；只表示 M12-04 的“补偿裁定面板 → 真实权威 → 现金与
文档”端到端切片，不表示 M12-04 已完成。
日期：2026-11-16。

## 问题

[RECORD-20](RECORD-20-dispute-enforcement.md) 已在
`tests/dispute_authority_test.gd` 覆盖补偿执行，并在
`tests/dispute_panels_network_test.gd` 之外补了面板金额输入；但“管理员在真实
面板选择补偿、填写金额、确认 → 真实 `WorldClient` → 真实 `world_server.gd`
→ `disputes.json` + `farm.json` 账本”的完整链路没有验证。本切片补上：

- 面板选择 `compensation` 时费用字段出现，金额随裁定命令下发；
- `disputes.json` 的裁定与 `enforcement.paid=true` 落盘；
- 平衡账本分录 `dispute_compensate_<case>` 与双方现金精确变化；
- 同一裁定命令重发返回 `duplicate`，现金与文档不再变化；
- 余额不足时面板显示权威拒绝文案，案件保持 `accepted`，现金不变；
- 非管理员成员与访客提交补偿均被 `forbidden`，现金不变；
- 权威重启后文档、余额与“只转一次”的标记保留。

## 边界

- 只新增 `tests/dispute_compensation_network_test.gd` 与本记录；没有修改
  `Game/`、`.github/`、PLAN 或 `rules/`。
- 面板仍不判断权限、余额、账户或案件状态；每个拒绝与结果都来自真实权威
  回复，测试只核对面板文本、文档与账本。
- 使用一个房主/管理员、一个立案人、一个被裁定方和一个具名访客；被裁定方
  与立案人各自通过真实 `account_open` 命令获得 120 开户口赠款。
- 不新增补偿语义、退款、撤销、其他处罚形式或多管理员合议。

## 实现

### 测试：`tests/dispute_compensation_network_test.gd`

按 `Game/scenes/main.gd` 的接线挂载真实 `DisputePanel`：`dispute_action` 原样
转发面板生成的 `command_id`，`refresh_requested` 请求 `dispute-state`，
`client.dispute_result` 同时接到面板 `apply_result` 与测试记录。真实权威以
`--host-player=PLAYER_A` 启动，回环 WSS，RPC 23/24；同一进程只开一个
`WorldClient`，连接依次打开：

1. **被裁定方 T**：提交 `account_open` 真事件，现金 120，`issued=120`。
2. **立案人 B**：提交 `account_open`，现金 120；通过面板立案
   `case_comp_network_1` 与 `case_comp_network_poor`，被裁定方均为 T，引用
   真实事件；检查两案落盘。
3. **房主 A**：受理两案。对第一案选中“补偿”，确认金额字段由隐藏变为可见，
   填 30 后按“裁定”；先取消确认框验证不发请求、文档与视图不变，再确认并
   等待真实回复。随后重发捕获到的同一 `command_id` 与参数。
4. **立案人 B**：对仍为 `accepted` 的第二案尝试补偿 10，权威返回
   `forbidden`，面板原样显示 `reason_text`。
5. **访客**：只看到两条公开状态行；尝试同一补偿也被 `forbidden`。
6. **房主 A（重启后）**：权威停止并同目录重启，检查 `disputes.json` 字节
   不变、`paid` 标记与余额保留，再重发同一裁定命令。

现金证据（读 `farm.json` 后用 `FarmState.restore_snapshot()` 取权威 API）：

| 时点 | 立案人 B | 被裁定方 T | issued | 总现金 |
|---|---|---|---|---|
| 开户后 | 120 | 120 | 240 | 240 |
| 30 补偿后 | 150 | 90 | 240 | 240 |
| 重放/重启后 | 150 | 90 | 240 | 240 |

`disputes.json` 的 `enforcement[case_comp_network_1]` 为
`{amount: 30, at_utc: >0, paid: true}`；`farm.json` 账本只有一条
`dispute_compensate_case_comp_network_1`，kind 为 `pay`，两行分别为
`account:PLAYER_B` 借记 30、`account:PLAYER_T` 贷记 30。

## 覆盖矩阵

| 要求 | 测试证据 |
|---|---|
| 面板选择补偿、金额字段显隐、确认框提交 | `The compensation amount starts hidden`、`Selecting compensation reveals the amount field`、`The compensation confirmation warns that cash will be transferred`、`The administrator's compensation rule lands on the authority` |
| 面板转发金额 | `The panel forwarded the amount with the ruling command` |
| `disputes.json` 裁定与 `enforcement.paid=true` | `disputes.json persists the compensation ruling and its author`、`disputes.json records the compensation as paid exactly once` |
| 平衡分录 `dispute_compensate_<case>` | `The compensation is a balanced pay ledger entry`、`The ledger debits the filer and credits the sanctioned party` |
| 双方现金精确变化、issued 不变、reconcile | `The filer receives exactly the compensation amount`、`The sanctioned party pays exactly the compensation amount`、`The compensation issues no new cash`、`The compensation conserves total cash`、`The ledger reconciles after the compensation` |
| 同命令重发 `duplicate`、不二次转账 | `Resending the same ruling command returns duplicate`、`A duplicate ruling moves no cash and issues nothing`、`A duplicate ruling adds no ledger entry`、`A duplicate ruling leaves both documents byte-identical` |
| 重启后文档/余额保留、不二次转账 | `The restart loads disputes.json without rewriting it`、`Both compensation balances survive the restart exactly once`、`Exactly one compensation ledger entry exists after the restart`、`The same ruling command still replays after the restart`、`The post-restart replay transfers no cash a second time` |
| 余额不足：面板显示权威文案、案件未裁定、现金不变 | `An unaffordable compensation is refused by the authority`、`The panel shows the authority's refusal text verbatim`、`The refused case stays accepted`、`The refused case records no paid marker`、`A refused compensation moves no cash and still reconciles` |
| 非管理员成员 `forbidden`、现金不变 | `A non-administrator member's compensation is refused as forbidden`、`The unauthorized member attempt moves no cash` |
| 访客 `forbidden`、现金不变 | `A visitor's compensation is refused as forbidden`、`The visitor's refused compensation moves no cash` |
| 取消确认框不发请求、不写文档 | `Cancelling the compensation confirmation sends nothing`、`A cancelled compensation leaves the view and document unchanged` |
| 被拒绝的裁定不写文档 | `The refused ruling writes no authority document`、`The unauthorized member attempt writes no authority document`、`The visitor's refused compensation writes no authority document` |

## 验证

实际运行命令：

```sh
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 420 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/dispute_compensation_network_test.gd"
```

原始末行（连续三次一致，单次约 5 秒）：

```text
DISPUTE_COMPENSATION_NETWORK_TEST checks=133 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-compensation-network-415832
DISPUTE_COMPENSATION_NETWORK_TEST checks=133 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-compensation-network-368657
DISPUTE_COMPENSATION_NETWORK_TEST checks=133 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-compensation-network-388114
```

解析检查：`--check-only --script tests/dispute_compensation_network_test.gd`
无输出错误。

### CI 归类

该测试真实挂载 `DisputePanel`，后者 preload `FarmTheme`，而 `FarmTheme`
preload 艺术字体，因此属于 scene test，需要艺术资源 check out。本任务不允许
修改 `.github/`，未加入 CI 列表；后续维护时应放入 `scene_tests`。

## 未覆盖

- 真实 TCC 权限弹窗、真实鼠标点按/窗口焦点/输入法；测试直接 `emit` 按钮信号。
- Windows；只在 macOS 无头 Godot 上运行。
- 多管理员或两个客户端同时裁定同一案件、命令令牌桶限频下的竞争；同一时刻
  只有一个 `WorldClient` 连接。
- 真实跨机网络、TLS 证书轮换、断线重连期间发起补偿裁定。
- 补偿的撤销/退款、反向后向分录、其他处罚形式（封禁、恢复备份、权属更正）。
- `paid=true` 写回失败后继续运行并写满账本容量的组合故障（见 RECORD-20）。

## 关联

- [M12 计划](PLAN.md) 的 M12-04 段（本记录不修改计划）。
- [RECORD-20 · 纠纷事件核验与补偿执行](RECORD-20-dispute-enforcement.md)。
- [RECORD-19 · 纠纷面板真实网络联调](RECORD-19-dispute-panels-network.md)。
- [RECORD-18 · 纠纷面板](RECORD-18-dispute-panel.md)。
- 实现：`Game/ui/dispute_panel.gd`、`Game/world/world_client.gd`、
  `Game/world/world_host.gd`、`Game/world/headless_world.gd`、
  `Game/world/disputes_store.gd`、`Game/farm/economy_state.gd`。
- 测试：`tests/dispute_compensation_network_test.gd`、
  `tests/dispute_panels_network_test.gd`、`tests/dispute_authority_test.gd`。
