# M4-09 · 共享世界经济命令（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M4 或验收完成。前置：[M4-07 开房与加入](RECORD-07-rooms.md)，规则见 [ADR-019](../../decisions/ADR-019-economy-command-permissions.md)，底层账本、市场、银行与贷款分别见 [ADR-014](../../decisions/ADR-014-double-entry-ledger.md)、[ADR-011](../../decisions/ADR-011-market-orders.md)、[ADR-017](../../decisions/ADR-017-bank-loans.md)。

## 问题

账户、付款、市场、物流、银行和贷款规则只在本机状态上可用；共享世界的成员无法开户、付款或交易。接入网络前还必须满足两个已有边界：命令里的付款人/借款人不能由客户端声明；[ADR-014 §6.1](../../decisions/ADR-014-double-entry-ledger.md) 记录的“命令窗口淘汰后 `pay` 重放会二次转账”必须先修掉。

## 实现

| 文件 | 改动 |
|---|---|
| `Game/farm/farm_command.gd` | 十种经济命令的 `make_*`、精确键集校验、actor 绑定载荷、`_apply`；支付携带必填 `seq` |
| `Game/farm/economy_state.gd` | `pay` 接受可选 `seq` 并维护 `pay_seq`；账户校验接受该字段；恢复时归一化旧文档 |
| `Game/farm/farm_state.gd` | `economy_pay` 透传可选 `seq`（最小改动） |
| `Game/world/world_invite.gd` | 成员权限加入全部经济命令；访客仍只有 `water`/`weed` |
| `Game/world/headless_world.gd` | 固定顺序权威扫描；命令与 `advance_to` 都触发；结果计数进入回复 |
| `Game/world/world_host.gd` | 经济命令门禁、`reason_text`、成功后广播世界摘要 |
| `tests/m4_economy_commands_test.gd` | 真实 WSS 回路、双成员 + 访客 + 观察者、窗口淘汰与 `stale_sequence` 用例 |

### 命令与身份

新增命令：`account_open`、`pay`、`market_open`、`market_place`、`market_cancel`、`market_ship`、`market_deliver`、`bank_open`、`loan_borrow`、`loan_repay`。

- `market_open` 是需求清单之外补上的第十种：开商人也是世界级一次性动作，必须与 `bank_open` 一样走候选提交、幂等和广播。
- 所有经济命令的 `actor` 都由 `WorldHost._player_id(peer_id)` 解析；命令载荷出现 `from`、`from_id`、`owner`、`owner_id`、`payer`、`borrower` 任一即 `invalid_command`。
- 匿名成员执行经济命令返回 `no_player`。

### 权限矩阵

| 命令 | member | visitor |
|---|---|---|
| `account_open` / `pay` / `market_open` | 允许 | `forbidden` |
| `market_place` / `market_cancel` / `market_ship` | 允许，只能操作本人订单/账户 | `forbidden` |
| `market_deliver` / `bank_open` | 允许（世界级一次性动作） | `forbidden` |
| `loan_borrow` / `loan_repay` | 允许，借款人/还款人只能是本人 | `forbidden` |
| `water` / `weed` | 允许 | 允许（不变） |

社交协作授权不扩大经济权限；`401` 之前分支不读 `_grant_allows`。

### 权威扫描

提交成功后与 `advance_to` 后按固定顺序运行，无命令 id、不由客户端触发：

```text
market_expire → market_match → market_deliver → economy_settle_loans
```

命令路径在候选状态上、`save_state` 前运行，因此命令、扫描结果和事件序列落在同一份快照；扫描失败则整个命令失败。单机路径不自动扫描，行为不变。

经济截止时间（订单到期、到达、贷款到期）不会产生生长事件。部署型权威 `world_server.gd` 每秒用 `HeadlessWorld.settle_economy_now(clock)` 补扫：候选副本上跑同一固定顺序，有变化才保存并 `accept`，失败时活状态不变；它不推进 `now_utc`、不结算生长。测试 `world_economy_clock_test` 覆盖“无命令、无生长事件时订单到期与贷款逾期”和重复扫描幂等。

### `pay_seq` 与窗口淘汰

- 位置：`economy.accounts[owner].pay_seq`，默认 0，旧档恢复时补为 0；不新增农场顶层键，格式仍为 27。
- `pay` 新增必填 `seq`（正安全整数）。`seq <= pay_seq` 返回 `ok=false, reason="stale_sequence"`，余额、账本和 `pay_seq` 都不变；成功时在同一候选提交中更新 `pay_seq = seq`。
- 只要求严格递增，不要求连续。同 id 同载荷仍先回放原结果。
- 直连单机/测试调用可省略 `seq`，旧载荷格式继续可回放；网络命令始终携带。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
"$GODOT" --headless --path Game --script "$PWD/tests/m4_economy_commands_test.gd"
```

结果：

```text
M4_ECONOMY_COMMANDS_TEST checks=162 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-economy-commands-332879
```

覆盖：两名成员开户/付款；伪造 sender 被 `invalid_command` 拒绝；守恒 `total_cash == issued`；A 收获并挂卖单、B 买入成交、重复买单只成交一次；撤单、发货、交付；开商人并成交；开银行、借款、他人代还拒绝、本人还款、重复借款；访客所有经济命令 `forbidden` 且世界不变、浇水/除草仍可用；未认证连接无回复；重连后重放已提交 id 返回 `duplicate`；停止后重开磁盘，账户/合同/订单一致，`Economy.valid`、`Market.valid`、`Loans.valid` 全通过。

时钟与窗口边界（后续切片）：只有经济窗口保留受理结果时按 `duplicate` 处理，不提交、不保存、不广播；未来 1e7 秒的命令返回 `time_forwards`，时钟与经济状态都不变；非对象命令载荷两次都返回 `invalid_command`，不产生脚本错误也不提交事件。

`pay_seq` 用例（`tests/m4_economy_commands_test.gd:341-371`）：

| 用例 | 实际观察 | 结果 |
|---|---|---|
| 成功付款后同 id+seq 重试 | `duplicate=true`，不二次转账 | 通过 |
| 清空 FarmState 与 economy 两个命令窗口后同 id+旧 seq | `stale_sequence`，余额不变 | 通过 |
| 清空窗口后新 id+旧 seq | `stale_sequence`，余额不变 | 通过 |
| 新 id+更大 seq | 成功，只移动一笔 10 | 通过 |

守恒数据（最终存档）：`issued=total_cash=2836`；账户 A=102（`pay_seq=2`）、B=145（`pay_seq=0`）、银行=1983、商人=266、买单托管=340；发行 240（两份开户）+ 2000（银行资本）+ 600（商人预算）= 2840，销毁 4，净发行 2836。

回归（同一引擎，原始末行）：

```text
ECONOMY_INITIAL_TEST checks=154 failures=0
LEDGER_TEST checks=1841 failures=0
LOAN_TEST checks=1885 failures=0
MARKET_ORDERS_TEST checks=191 failures=0
MARKET_ARCHIVE_TEST checks=2660 failures=0
MARKET_LOGISTICS_TEST checks=174 failures=0
MARKET_MATCHING_TEST checks=241 failures=0
MARKET_SUPPLY_DEMAND_TEST checks=1220 failures=0
M4_SYNC_TEST checks=39 failures=0
M5_GRANT_TEST checks=36 failures=0
M5_GIFT_TEST checks=37 failures=0
M4_AUTH_TEST checks=24 failures=0
M4_JOIN_TEST checks=54 failures=0
M4_RECONNECT_TEST checks=31 failures=0
M4_SERVER_TEST checks=51 failures=0
M4_HOSTING_TEST checks=25 failures=0
M4_PRESENCE_TEST checks=25 failures=0
M4_ACTIVITY_TEST checks=18 failures=0
M4_MOVE_TEST checks=31 failures=0
WORLD_TAIL_TEST checks=27 failures=0
WORLD_SNAPSHOT_TEST checks=31 failures=0
```

需求提到的 `m4_grant_test.gd` 在仓库中不存在，实际文件是 `tests/m5_grant_test.gd`。

权威时钟补扫（本记录写入后补做）：

```text
M4_ECONOMY_COMMANDS_TEST checks=137 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-economy-commands-386075
WORLD_ECONOMY_CLOCK_TEST checks=32 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-economy-clock-39071
M4_SERVER_TEST checks=51 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-server-310460
M4_HOSTING_TEST checks=25 failures=0
```

`world_economy_clock_test` 覆盖：10 秒后到期的买单在没有命令、没有生长事件时由时钟扫描置 `expired` 并释放托管；7 天贷款在 8 天后置 `overdue` 且费用不增长；同一时刻第二次扫描 `changed=false` 且关闭时间不移动；作物字段与农场事件序号不变；重开磁盘仍有到期订单与逾期合同；未开世界和 `NAN`/`INF`/负时间被拒绝。

## 双平台 CI

2026-11-15，`7b8b74d` 在 `rule-tests.yml`（run 43688308623）上双平台通过：

```text
macOS   m4_economy_commands_test M4_ECONOMY_COMMANDS_TEST checks=137 failures=0
macOS   world_economy_clock_test WORLD_ECONOMY_CLOCK_TEST checks=32 failures=0
macOS   rule fixtures: 64 listed, 7 skipped for missing art
Windows m4_economy_commands_test M4_ECONOMY_COMMANDS_TEST checks=137 failures=0
Windows world_economy_clock_test WORLD_ECONOMY_CLOCK_TEST checks=32 failures=0
Windows rule fixtures: 64 listed, 7 skipped for missing art
```

清理检出不含 LFS 美术，`bank_panel_test` 等 7 个场景夹具按既有规则跳过；真实 WSS 回路在两端都跑通。

## 未覆盖

- 共享世界客户端 UI 接线（下单、撤单、借贷面板）不在本切片；命令只能由测试或已有客户端入口提交。
- 跨平台真实硬件未验证；本记录只有 macOS 本机回路。
- 窗口淘汰后的市场扫描幂等仍是已知边界：`market_match`/`market_deliver`/`market_cancel` 重试可能重跑扫描并返回不同计数，但订单行、`closed_by` 和耐久成交/交付行阻止二次记账。`pay` 已由 `pay_seq` 补上。
- 没有审计导出、退款或争议流程；没有 `seq` 跨设备并发分配协议，客户端需自行单调递增。
- 没有修改任何 `PLAN.md`、决策索引、场景或 UI 文件。
