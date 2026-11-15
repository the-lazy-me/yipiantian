# ADR-027 · 摘要可见性：按收件人投影 world summary / snapshot

- 状态：裁决完成（2026-11-15，三项产品取舍已拍板），**未实现**；R19 仍开放，关闭条件见 §7。
- 关联：[RISKS](RISKS.md) R19/R18/R20、[ADR-026 载荷上限](ADR-026-network-payload-limits.md)、[ADR-019 经济命令权限](ADR-019-economy-command-permissions.md)、[ADR-011 市场订单](ADR-011-market-orders.md)、[ADR-012 撮合结算](ADR-012-matching-settlement.md)、[ADR-013 物流](ADR-013-limited-logistics.md)、[ADR-014 复式账本](ADR-014-double-entry-ledger.md)、[ADR-017 银行贷款](ADR-017-bank-loans.md)、[ADR-022 损失证据](ADR-022-insurance-loss-evidence.md)、[载荷实测](../research/PAYLOAD-BUDGET.md)、`tests/world_projection_test.gd`（待新增）。
- 范围：服务端→成员的 world 摘要、快照、`change`/`catch_up` 事件与社交视图的**内容可见性**；不改经济规则、命令权限、存档格式或权威校验。
- 行号说明：本文行号取自 2026-11-15 当前工作树。工作树同时有 R20 限频等并行改动，行号可能继续移动；以函数名和文档中的代码引用为准。

## 背景

### 1. 当前广播路径确实向每个成员发送完整权威状态

`WorldHost._broadcast_summary()` 先构造一份 `world.summary()`，再把 `world.state_snapshot()` 整份放进 `snapshot`，然后**逐 peer**复制并补 `role`：

- `Game/world/world_host.gd` `_broadcast_summary`（当前第 1127–1138 行）：`base = world.summary()`，`base["snapshot"] = world.state_snapshot()`，`for peer_id: view = base.duplicate(true); view["role"] = ...; _send_summary(...)`。
- `Game/world/world_host.gd` `request_summary`（当前第 1202–1217 行）：同一份 `world.summary()` 与 `world.state_snapshot()` 发给请求者。
- `Game/world/headless_world.gd` `summary`（第 513–539 行）：`"bags": snapshot.bags.duplicate(true)` 是**所有玩家**的口袋；`state_snapshot`（第 502–510 行）返回 `farm.snapshot()`，即含 `bags` 与完整 `economy` 的持久化文档。
- `Game/farm/farm_state.gd` `snapshot`（第 115–116 行）只做深拷贝；`_data` 的顶层键见第 95 行：`fields/harvested/inventory/bags/theft/buildings/neighbors/layout/kitchen/animals/memories/season/transaction/economy`。
- 经济子文档含 `accounts`、`ledger`、`loans`、`market` 等；键集见 `Game/farm/economy_state.gd` `STATE_KEYS`（第 30–33 行），账本键集见 `Game/farm/ledger_state.gd` `STATE_KEYS`（第 83 行），市场行见 `Game/farm/market_state.gd` `MARKET_KEYS/ORDER_KEYS/TRADE_KEYS/SHIPMENT_KEYS/DELIVERY_KEYS`（第 165–198 行）。

因此 R19 描述的不是理论风险：普通规模世界 summary+snapshot 已 100,035 B，结构上限 692,623 B；其中结构上限的 `economy` 占 524,423 B（公开市场行 381,717 B、账本 141,347 B、所有账户 441 B），所有玩家 `bags` 1,422 B（[PAYLOAD-BUDGET](../research/PAYLOAD-BUDGET.md) §2）。

### 2. `restore_state` 目前要求“完整权威文档”，这正是 R19 不能只删字段的原因

`Game/world/world_member.gd::restore_state`（第 212–237 行）把 `snapshot.farm` 交给 `FarmState.restore_snapshot()`。后者调用 `_valid_snapshot`（`Game/farm/farm_state.gd` 第 1390–1440 行），要求：

- 十个以上固定键与精确大小；`bags`/`theft`/`buildings`/`economy` 可缺省，但**存在时必须通过各自的严格校验**；
- `Economy.valid`（`Game/farm/economy_state.gd` 第 63–160 行）要求 `accounts` 现金总额、商人现金、托管、银行现金与 `issued` 精确相等，并且 `Ledger.valid`/`reconcile` 能由分录复现每个余额（第 126–157 行）。

所以只把 `bags` 换成“本人”，或把 `accounts` 换成“本人”，客户端会直接 `invalid_farm`；如果先删账本又不改校验，反而会把“少发数据”伪装成“世界损坏”。[ADR-026](ADR-026-network-payload-limits.md) §“R18 与 R19 的关系”已经明确：R19 需要先裁决“每种角色能看到哪些字段”和“裁剪后客户端是否还能重建权威状态”。本 ADR 回答这两点。

### 3. 当前 UI 已经把“他人”匿名化，完整 id 与账本没有当前消费方

以下是本次调查确认的**已经是公开信息**或**已经不需要原始身份**的证据：

| 事实 | 证据 |
|---|---|
| 市场价格、商人 bid/ask、预算与库存本来就是公开的 | `Game/farm/market_state.gd::quote`（第 553–584 行）把 `merchant.cash` 映射为 `budget`、`merchant.goods` 映射为 `stock` 并返回给所有调用方；`Game/ui/market_panel.gd` `_sync_price`（第 506–512 行）直接用 `ask/bid`。 |
| 订单簿（方向、商品、价格、数量、剩余、托管、状态）向所有人展示 | `Game/scenes/main.gd::_market_view`（第 1683–1721 行）把 `market_orders()/market_shipments()/market_deliveries()/market_quotes()` 交给面板；`Game/ui/market_panel.gd::_order_text`（第 409–425 行）显示这些字段。 |
| 订单所有者只显示为“我/商人/他人”，原始 id 从不出现在文本里 | `Game/ui/market_panel.gd::_order_text` 第 415 行。 |
| 发货与交付对所有人展示，文本不含 owner | `Game/ui/market_panel.gd::_shipment_text`（第 456–476 行）与 `_fill_deliveries`（第 479–495 行）。 |
| 银行现金、资本、未结清本金、已收费用是公开聚合 | `Game/ui/bank_panel.gd::_summary_text`（第 201–207 行）。 |
| 贷款合同只显示“我/他人”，不显示借款人 id | `Game/ui/bank_panel.gd::_contract_text`（第 262–269 行）。 |
| 本人的口袋本来只随本人回复下发 | `Game/world/world_host.gd` `execute_for_member` 的 `reply["bags"] = world.farm.bag(actor)`（第 568–571 行）注释即“不把其他成员的口袋发给请求者”。 |
| 本人账户是唯一被客户端读取的账户 | `Game/scenes/main.gd::_has_granted_account`（第 1770–1776 行）只查 `accounts[player_id]`。 |
| 成员名册的 `name/player_id/role` 是有意公开的社交入口 | `Game/world/world_host.gd::_broadcast_roster`（第 216–239 行）。 |

结论：市场公开字段（价格、方向、数量、状态、托管、商人库存）必须继续放行；但**原始 owner id、其他账户余额、账本、成交对手方、损失受害者和经济命令载荷**没有当前 UI 消费方，属于“发了但没人看”的暴露。

## 裁决

### 1. 一条原则：权威状态完整，网络文档按收件人白名单投影

- 权威进程继续持有完整 `FarmState`（含所有 bags、账本、账户、贷款、订单）。**不改变任何规则、存档格式或权威校验**。
- 任何服务端→成员的 world 文档都必须由**投影函数**从权威状态生成；不存在“把权威快照整份发给成员”的路径。
- 投影只做“字段是否出现”的选择，不重算规则、不重写余额、不改变命令结果。
- 身份只来自连接（ADR-019 §1）；投影的 `viewer` 由 `WorldHost._player_id(peer_id)` 解析，绝不读取客户端声明。

### 2. 权威文档与传输视图分离

新增一个纯函数模块（建议 `Game/world/world_projection.gd`），提供：

```text
project_summary(world, viewer, role, sequence) -> Dictionary
project_snapshot(world, viewer) -> Dictionary
project_change(entry, viewer) -> Dictionary
project_tail(events, viewer) -> Array
```

约束：

1. 输入只读；不得修改 `world.farm.snapshot()` 或任何权威表。
2. `snapshot` 顶层带投影标记：`"view": {"version": 1, "viewer": player_id, "role": role}`。`role` 是连接授予的角色，不是客户端声明。
3. `WorldMember.restore_state()` 看到 `snapshot.view` 时走新的 `FarmState.restore_view(farm_data, viewer)`；没有标记时保持现有 `restore_snapshot()` 全量路径（供磁盘/权威夹具使用）。
4. `FarmState.restore_view` 复用现有逐表校验（fields/layout/kitchen/animals/memories/neighbors/buildings/theft/transaction），但**不调用** `Economy.valid`/`Ledger.valid`；经济部分由新的 `Economy.valid_view(state, viewer)` 校验形状、范围和 `owner_scope`。
5. 投影文档不能通过 `restore_snapshot()`（经济视图缺少账本/守恒校验，必然失败）；这样它永远不会被误当权威快照写盘或回传。
6. 所有发送仍走 ADR-026 的唯一发送缝：`_encode_document`/`_send_payload`/`_send_summary`/`_send_encoded`（当前 `Game/world/world_host.gd` 第 996–1027 行）。投影不能绕过 48 KiB 预算。

### 3. 字段矩阵

#### 3.1 角色与归属

角色：

- **host/authority**：本机权威，持有完整状态；不是网络收件人。若房主自己以客户端加入，按 member/visitor 投影。
- **member**：拥有可信玩家 id，可执行全部经济命令（ADR-019 §2）。
- **visitor**：可有玩家 id 和社交记录，但没有经济身份，不能开户/付款/下单/借贷；仍可浇水、除草、收礼。
- **anonymous**：无玩家 id；有 farm 权限但没有社交记录与经济身份，私区块为空。

归属只有三类：**公开**（所有收件人相同）、**本人**（只发给本人）、**他人**（不发送，或只发送去掉身份的公开记录）。

#### 3.2 summary 顶层

| 字段 | 当前来源 | 裁决 | 说明/证据 |
|---|---|---|---|
| `world_id`、`run_generation`、`sequence` | host 补入（1127–1138、1209–1217） | 公开 | 世界身份与权威序号。 |
| `role` | host 按 peer 补入 | 本人 | 自己的角色。 |
| `now_utc` | `HeadlessWorld.summary` 513–539 | 公开 | 权威时钟。 |
| `inventory` | 同上 | 公开 | 公共共享库存（匿名玩法/`@world`），不是任何玩家的 `bag`；见 `FarmState.pantry_view` 136–141。 |
| `harvested` | 同上 | 公开 | 世界累计收获。 |
| `bags` | 同上，当前为 `snapshot.bags` 全量 | **本人** | 投影为 `{viewer: 本人的稀疏口袋}`；anonymous 为空。 |
| `buildings` | 同上 | 公开 | 房屋在世界中可见，`owner` 用于判定“我的/拆除”。 |
| `fields` | 同上 | 公开 | 含 `planted_by`，作物归属是偷菜/授权/展示的公开事实；ADR-026 的超限回退仍可删除这份重复显示视图。 |
| `committed_commands`、`committed_sequence` | 同上 | 公开 | 计数。 |
| `next_event_utc` | 同上 | 公开 | 下一生长事件。 |
| `nature` | 同上 | 公开 | 天气/季节/灾害视图；客户端在摘要块过期后用快照 seed 推导（`main.gd::_weather_view` 2331–2344、`_current_disaster_mode` 3687–3698）。 |
| `snapshot` | `state_snapshot()` | 按 §3.3 投影 | 唯一可恢复的世界文档。 |

#### 3.3 snapshot / farm

| 路径 | 裁决 | 客户端需要它的原因 |
|---|---|---|
| `now_utc`、`decorations`、`nature` | 公开 | 时钟、院落、天气；`restore_state` 212–237。 |
| `farm.fields`、`harvested`、`inventory`、`layout`、`kitchen`、`animals`、`memories`、`season`、`neighbors`、`buildings` | 公开 | 完整玩法与显示；现有校验逐表保留。 |
| `farm.theft[viewer]` | 本人完整记录 `{enabled, day, lost, last}` | 本人偷菜/被偷的冷却与上限。 |
| `farm.theft[other]` | **中性记录** `{enabled, day: -1, lost: 0, last: {}}` | 本地回放邻居偷第三方时仍需 `enabled` 决定是否 `theft_disabled`；`last/lost/day` 是他人受害记录，不广播。用完整形状避免规则读取缺键。 |
| `farm.transaction.sequence` | 公开 | 事件序号。 |
| `farm.transaction.command_results` | 本人全部 + 他人的**非经济**命令；他人的经济命令删除 | 本地回放只需非经济命令的幂等结果；经济命令客户端从不本地回放（`main.gd::_on_remote_changed` 828–853）。 |
| `farm.transaction.gift_ids` | **从投影删除** | 客户端不再依赖它做重放判定（见 §5 的 duplicate 规则）；它可能达到 1024 条 × 512 B，是预算隐患。权威仍保留（R26 不变）。 |
| `farm.bags` | **本人** | 钱包、厨房、动物、礼物、收获；anonymous 为空。 |
| `farm.economy.currency` | 公开 | 固定币种。 |
| `farm.economy.accounts` | **本人** | 钱包、市场/银行开户判定（`_has_granted_account`）。 |
| `farm.economy.market.merchant` | 公开：`opened/opened_utc/cash/goods`；删除 `opened_by/granted` | 报价、库存、开市状态；`cash/goods` 已由 `quote()` 的 `budget/stock` 公开。 |
| `farm.economy.market.orders` | 公开行 + `owner_scope`；删除 `owner/closed_by/released/created_utc/expires_utc/closed_utc` | 订单簿本身公开；`owner_scope` 取 `me/merchant/other`，替代 UI 的“我/商人/他人”。`reserved`（托管）继续公开，因为面板对所有订单显示它。 |
| `farm.economy.market.shipments` | 公开行 + `owner_scope`；删除 `owner/fee/risk/lost_utc/loss_id/delivery_id/delivered_utc` | 面板显示商品、数量、路线、在途/损失状态；保留 `status/arrive_utc/depart_utc/sequence/id`。 |
| `farm.economy.market.deliveries` | 公开行；删除 `owner/shipment_id` | 面板显示商品、数量、路线；保留 `id/sequence/good/quantity/origin/destination/at_utc`。 |
| `farm.economy.market.trades` | **删除** | 当前 UI 不显示成交记录；成交行含买卖双方 id，是最小暴露下无当前需求的字段。 |
| `farm.economy.market.archived_*`、`sequence/trade_sequence/shipment_sequence/delivery_sequence` | **删除** | 只有权威归档/序号用途，客户端无消费方。 |
| `farm.economy.loans` | 匿名行 `{id, principal, fee, due_utc, status, owner_scope}`；删除 `borrower/opened_utc/term/paid/repaid_utc/repay_id` | 银行面板列出所有合同并只显示“我/他人”；聚合 `outstanding/fees` 由这些行即可正确计算（`LoanState.outstanding_principal/collected_fees` 288–313 只读 `status/principal/fee`）。 |
| `farm.economy.bank` | 公开：`opened/cash/capital`；删除 `opened_by/opened_utc` | 银行面板显示开市、现金、资本；开市人不是显示事实。 |
| `farm.economy.ledger` | **删除** | 完整复式账本含全部账户流水；客户端从不读取（`main.gd` 无 `economy_ledger` 调用）。 |
| `farm.economy.conversion` | **删除** | 仅 `economy_convert_demo` 使用，客户端无 UI。 |
| `farm.economy.command_results` | **删除** | 权威幂等窗口；客户端不执行经济规则。 |
| `farm.economy.losses` | **删除** | 面板只显示 `shipment.status == lost`；损失证据的 `victim/shipment_id` 是审计数据，不是成员显示字段。若未来 UI 需要，另加去身份的公开视图。 |
| `farm.economy.issued/total_cash/sequence` | **删除** | 客户端不读取；保留会暴露世界货币总量且无当前用途。 |

#### 3.4 社交、名册与事件

| 数据 | 当前是否在 summary/snapshot | 裁决 |
|---|---|---|
| 联系人、待处理邀请 | 否 | 已按查看者过滤：`SocialState.view`（`Game/social/social_state.gd` 575–599）只读 `players[viewer]`；`_apply_social` 用连接解析的 `viewer`（`world_host.gd` 728–813）。保持。 |
| 屏蔽 | 否 | 同上；`view.blocks` 只含本人记录。 |
| 合作授权 | 否 | `grants_view`（553–570）只返回 `from == viewer` 或 `to == viewer`；第三方看不到。 |
| 留言 | 否 | `inbox`（365–377）只返回公共消息、本人发出/收到的消息，并按屏蔽过滤；私有消息不会进入第三方视图。 |
| 访问记录 | 否 | `SocialState.initial_state` 有 `visits`（第 40 行），但 `view` 的返回（597–599）不含它；当前没有任何成员能看到访问记录。保持，并加回归断言。 |
| 名册 | 是（独立 `roster` 通道） | `name/player_id/role` 公开（`_broadcast_roster` 216–239）。`player_id` 是社交定位符，不是凭据（R16）；邀请/送礼/名册需要它。 |
| `change`/`catch_up` 的非经济命令 | 是 | 保留完整 `command` 与 `from_id/from_name`：邻居需要看到“谁做了什么”；`_announce_neighbour` 依赖它（`main.gd` 859–894）。 |
| `change`/`catch_up` 的经济命令 | 是（当前泄露 `pay` 金额、贷款本金、订单参数等） | **改为不透明序号占位** `{sequence, kind: "economy"}`：保留序号连续性，删除 `command` 与 `from_id/from_name`。权威仍执行并持久化原命令；投影只影响广播。`_apply_broadcast` 仍会推进 `last_sequence`，测试计数不因缺字段而错误。 |

#### 3.5 按角色的可见性矩阵（摘要）

| 数据 | host/authority | member（本人） | member（他人） | visitor（本人） | visitor（他人） | anonymous |
|---|---|---|---|---|---|---|
| `bags` | 全量本地 | 本人 | 不发送 | 本人 | 不发送 | 不发送 |
| `accounts` | 全量本地 | 本人 | 不发送 | 不发送（无经济身份） | 不发送 | 不发送 |
| `loans` | 全量本地 | 本人完整 + 他人匿名行 | 匿名行 | 无本人贷款 + 他人匿名行 | 匿名行 | 匿名行 |
| 订单/发货/交付 | 全量本地 | `owner_scope=me` + 他人匿名行 | 匿名行 | 只读匿名行 | 匿名行 | 匿名行 |
| `theft` | 全量本地 | 本人完整 + 他人中性 | 中性 | 本人完整 + 他人中性 | 中性 | 空/中性 |
| 账本、成交、损失证据、经济命令结果 | 全量本地 | 不发送 | 不发送 | 不发送 | 不发送 | 不发送 |
| 联系人/邀请/屏蔽/授权/留言 | 全量本地 | 本人视图 | 不发送 | 本人视图 | 不发送 | 空 |
| 名册、田地、房屋、厨房、动物、记忆、天气、装饰 | 全量本地 | 公开 | 公开 | 公开 | 公开 | 公开 |

### 4. 私有字段只能由本人拿到：选择 per-peer 投影（方案 A）

`_broadcast_summary` 现在就是逐 peer 构造的；把“投影”放在同一个循环里，不需要新的消息类型。对比：

| | A. per-peer 投影（采纳） | B. 公开摘要 + 本人按需私有摘要 |
|---|---|---|
| 请求次数 | 0 次新增；保持加入 1 次、重连 2 次、30 s reconcile 1 次、手动刷新 1 次（`world_member.gd` 134；`world_client.gd` 184–186、207、398） | 每次影响本人的经济提交/礼物至少再加 1 次私有请求；N 个受影响成员就是 N 次；否则钱包/口袋要等 30 s。需要新消息类型或 `request_summary(private)` 标志。 |
| 单条预算 | 每人一份投影，仍由 ADR-026 的 48 KiB 检查；私有块只含本人，通常远小于全量 | 公开文档一份 + 私有小文档；私有文档可单独限制得更小。 |
| 大型世界开销 | 每次广播 N 次投影 + N 次编码；现有实现本来已 N 次 `duplicate` + 编码，投影只增加过滤分配。若 N=64 且经济提交持续，CPU/分配线性放大 | 广播只编码一次公开文档，私有按需；N 大时带宽更省，但增加往返与陈旧窗口。 |
| 正确性/陈旧 | 无额外窗口；收件人在同一条广播里拿到自己的新余额/口袋 | 收款人、贷款人等需要额外往返；漏发时 UI 显示旧值，直到 reconcile。 |
| 失败面 | 复用现有发送缝与拒绝路径；投影是纯函数，容易单测 | 新增请求/合并状态机、授权校验、重试与乱序处理。 |

**裁决：采用 A。** 理由：现有 seam 已经是逐 peer；A 不新增消息类型、不增加往返、不引入陈旧窗口；私有块很小，而公开市场/田地本来就占文档主体，A 的额外带宽主要是滤掉账本/他人账户后的净减少。B 保留为触发条件后的逃生通道，见 §12。

投影实现要求：

- 公共部分只构造一次；每个 peer 只复制并附加本人的私区块。`owner_scope` 依赖 viewer，因此订单/发货/贷款行仍需按 peer 标记，但不需要重新排序或重算价格。
- 投影必须在 `_encode_document` 之前完成；不得为了让文档变小而在投影里删除可见字段。
- `tail_since` 的字节预算用**该 peer 的投影事件列表**计算，不用全量 tail；二分/裁剪逻辑不变（ADR-026 §3）。
- 投影不得改变 `sequence`；经济命令占位仍计入事件数量与连续性。

### 5. 客户端契约与降级

`restore_state()` 需要的最小字段：

1. `snapshot.view`（版本、viewer、role）→ 选择 `restore_view`，并要求 viewer 与 `WorldMember.player_id` 一致；不一致返回 `view_mismatch`。
2. `snapshot.now_utc`、`decorations`、`nature`：时钟、院落、天气。
3. `snapshot.farm` 的公开玩法表：`fields/layout/season/kitchen/animals/memories/neighbors/harvested/inventory/buildings/theft/transaction.sequence`。
4. 本人 `farm.bags`：钱包、厨房、动物、礼物、收获。
5. 本人 `farm.economy.accounts`：`economy_cash`、`_has_granted_account`。
6. 公开市场行 + `owner_scope`：市场面板（`_market_view` 1683–1721）。
7. `farm.economy.loans` + `owner_scope`、`farm.economy.bank`：银行面板（`_bank_view` 2120–2133）。
8. 非经济命令的 `command_results`：本地回放的幂等判定。

客户端行为调整（仅为视图/本地镜像，不改变权威规则）：

- **礼物**：本人发出的礼物以回复中的 `reply.bags` 为准；本人收到的礼物在 `change`/`catch_up` 中按命令的 `to_id/crop_id/amount` 对本人 bag 做一个**视图增量**，不再读取发送者 bag（发送者 bag 已不在本人文档里）。第三方之间的礼物不改变本人本地状态，只显示已有的通知。
- **重复回复**：`reply.duplicate == true` 时不再本地回放；以回复携带的本人 `bags` 或下一次摘要为准。这样 `gift_ids`/`command_results` 不再是本地幂等的唯一依据。
- **经济命令**：仍不本地回放（`_on_economy_committed` 1818 起），只显示“正在同步”，由随后的投影摘要给出本人余额/贷款。
- **订单/贷款按钮**：以 `owner_scope == "me"` 判定撤单/还款/拆除，不再比较原始 owner id。
- **缺字段降级**：
  - 无本人 `bags` → 钱包显示 0、收到礼物时等待摘要；HUD 显示“个人资料同步中”，不能把 0 当权威。
  - 无本人 `accounts` → 市场/银行进入只读并提示“资料不完整”，不能显示 0 后允许下单。
  - 无本人贷款行 → 还款按钮禁用；聚合仍可由匿名行计算。
  - 无 `owner_scope` → 撤单/还款/拆除按钮隐藏（宁可不能点，不可点错）。
  - 他人 `theft` 中性记录导致本地回放第三方偷菜判断偏差 → 只影响画面一致性；下一次摘要校正。
  - `view` 缺失但文档又是投影形状 → `restore_snapshot` 失败并返回具名原因；不会半应用。
  - `snapshot.farm.economy` 整体缺失 → 市场/银行显示“不可用”，不得用空经济伪造“0 余额”。

### 6. 迁移与测试边界

**不迁移**：权威存档、农场格式 27、经济子文档、`RULES_VERSION`、命令载荷、权限表、扫描顺序都不变。投影只发生在传输前；权威仍按原格式落盘。

**协议**：摘要/快照形状改变。实现切片应提升 `PROTOCOL_VERSION`（当前 `Game/world/world_host.gd` 第 22 行附近），让旧客户端在 join 阶段被明确拒绝；如果维护者确认不存在独立部署的旧客户端，可沿用 ADR-026 的取舍保持版本号，但必须依赖 `view` 标记让旧客户端得到具名 `invalid_farm`/`view_mismatch`，不能静默把投影当全量。

**会失效或需要修改的现有断言**：

| 测试 | 现有断言 | 处理 |
|---|---|---|
| `tests/m5_gift_test.gd` 198–202 | 从观察者的 summary 恢复后同时读 `bags["actor"]` 与 `bags["watcher"]`，并断言 `actor_bag[CROP] == 0` | 改为只断言本人 `watcher` 的口袋；新增“快照不含 actor 的 bag”断言。 |
| `tests/world_snapshot_test.gd` 97–109 | 用完整 `state_snapshot()` 恢复并逐字段等于权威 | 保留为“权威全量校验器”夹具；另加投影夹具，断言公开字段相等、本人 bag/account 相等、他人私有字段不存在。 |
| `tests/world_payload_test.gd` 110–121、202–210、358–364 | 解码完整 `state_snapshot()` 后 `restore_state()` 等价于权威 | 把成员路径改成投影文档；新增投影字节预算与“无他人 bags/账本”断言；保留全量路径用于编解码保真测试。 |
| `tests/village_beta_test.gd` 340–345、396–408 | 从本人视图读本人 bag；摘要字节/单元格上限 | 本人 bag 仍应通过；新增“不含对方 bag/account/ledger”断言；`MAX_SUMMARY_BYTES` 可继续作为上界。 |
| `tests/m4_economy_commands_test.gd` 441–443 | watcher 的 `summaries > 1`、`remote_changes > 0` | 经济 `change` 变成不透明占位后仍应计数；若实现删除事件则必须改断言，本文要求保留占位。 |
| `tests/m4_sync_test.gd` | 观察者收到 1 条 harvest change | 非经济事件不变，应继续通过。 |
| `tests/world_tail_test.gd` | 256 条连续、`tail_expired`/`floor` | 用逐 peer 投影事件重跑连续性；新增经济占位事件的连续性断言。 |
| `tests/m4_client_scene_test.gd`、`tests/m4_reconnect_test.gd` | 客户端恢复后的 layout/inventory/buildings | 这些公开字段不变；应继续通过。 |
| `tests/player_bags_test.gd`、`long_soak_test.gd` 等 | 直接调用权威 `world.summary()`/`FarmState.snapshot()` | 不经过投影，保持原样。 |

**新增夹具（建议 `tests/world_projection_test.gd`）**：

1. 构造 A/B/C 三个成员（至少 A 有 bag、account、loan、订单、发货、交付、礼物；C 阻止 A）。分别取 A 的投影：
   - 断言 `snapshot.farm.bags` 只有 A；`accounts` 只有 A；`loans` 不含 B/C 的 borrower；`ledger`/`conversion`/`trades`/`losses`/`economy.command_results` 不存在；
   - 断言 A 的订单/发货/贷款行有 `owner_scope`，B/C 的行没有原始 id；
   - 断言 `snapshot.view.viewer == A`。
2. 公开字段等价：A 的投影与权威快照逐项比较 `fields/harvested/inventory/layout/kitchen/animals/memories/season/neighbors/buildings/decorations/nature` 完全相等；`sequence/role` 不变。
3. 本人私有等价：A 的 `bags[A]`、`accounts[A]`、`loans` 中属于 A 的行与权威相等。
4. 负向：把 B 的 bag 手工塞进 A 的投影后 `restore_view` 必须拒绝（`invalid_view`/`private_field`）；把投影交给 `restore_snapshot` 必须失败。
5. 本地回放：A 收获、A 送礼、B 送给 A 的礼物、A 收到礼物的重复回复、B 在 A 地块偷菜；断言 A 的本地 bag/fields 与权威一致（第三方偷菜允许一次摘要内校正）。
6. 经济命令载荷：A 给 B 付款后，B 的 `change`/`catch_up` 只能看到 `{sequence, kind:"economy"}`；A/B/C 的摘要都不含 `pay` 的 to/amount 原载荷。
7. 社交回归：A 的 `SocialState.view` 不含 B 的联系人/屏蔽/授权/留言；summary/snapshot 中不存在 `contacts/pending/blocks/grants/inbox/visits` 键；`visits` 不出现在任何网络文档。
8. 预算：空/普通/结构上限三个世界，按每个角色的投影文档 `WorldPayload.encode`，断言 `wire_bytes <= 49,152`；结构上限世界必须记录原始/压缩/线上字节。
9. 角色：member/visitor/anonymous 各取一次投影；visitor 没有 `accounts`、没有本人贷款；anonymous 没有私区块且不报错。
10. 发送缝：`world_host.gd` 中除 ADR-026 的助手外没有新的 `command_result.rpc_id`/`_social_reply.rpc_id` 调用（沿用 ADR-026 验收 6）。

### 7. R19 关闭验收

R19 只有在以下证据全部取得后才能从“未修”改为“已关闭”：

1. **无他人私有字段**：两成员以上世界的任一成员 summary/snapshot/change/catch_up 中，不存在他人的 `bags` 条目、`accounts` 条目、贷款 `borrower`、`ledger`、`conversion`、`trades`、`losses`、经济命令载荷。断言来自 `world_projection_test` 的跨成员扫描，而不是只测单人。
2. **本人私有完整**：本人的 bag、account、贷款行、theft 记录在该成员的投影中存在且与权威相等；重复摘要/重连后仍相等。
3. **公开玩法不回退**：市场面板仍显示所有订单/发货/交付的价格、数量、状态；银行面板仍显示所有合同行（匿名）与现金/资本/未结清/费用；本人钱包、院落、厨房、动物、天气、房屋不变量与投影前一致。现有 `village_beta`、`m4_client_scene`、`m5_social` 回归通过。
4. **恢复契约**：投影文档经 WireMember 解码后 `restore_state()` 返回 `ok`；公开字段与权威逐项相等；本人 bag/account/loans 相等；投影不能通过 `restore_snapshot()`。
5. **预算**：空/普通/结构上限世界的投影文档经 `WorldPayload.encode` 后 `wire_bytes <= 49,152`；若结构上限投影仍超限，必须记录实际字节并按 ADR-026 的 `fields`/拒绝回退处理，不能静默丢弃。
6. **事件通道**：经济命令在 `change`/`catch_up` 中只以 `{sequence, kind:"economy"}` 出现；非经济命令保持完整；`catch_up` 的“无空洞”与 `tail_expired` 语义不变。
7. **社交回归**：联系人/邀请/屏蔽/授权/留言只出现在本人社交视图；`visits` 不出现在任何网络文档。
8. **既有测试**：`WORLD_PROJECTION_TEST`、`WORLD_PAYLOAD_TEST`、`WORLD_TAIL_TEST`、`WORLD_SNAPSHOT_TEST`、`M4_SYNC_TEST`、`M4_CLIENT_SCENE_TEST`、`M4_RECONNECT_TEST`、`M4_ECONOMY_COMMANDS_TEST`、`M4_SERVER_TEST`、`M5_SOCIAL_TEST`、`M5_GIFT_TEST`、`M5_GRANT_TEST`、`VILLAGE_BETA_TEST` 全部通过；更新后的断言在提交信息中列出。
9. **无旁路**：唯一发送缝仍是 `_encode_document`/`_send_payload`/`_send_summary`/`_send_encoded`；投影函数是 summary/snapshot/change/tail 的唯一构造点。
10. **R18/R20 不冒充**：R19 关闭不以压缩/分块或限频作为证据；R18 的 48 KiB 与 R20 的令牌桶分别保持自己的验收。真实 WSS 多成员会话中的投影摘要端到端仍应单独记录。

### 8. 与 ADR-026 / ADR-019 的边界

**与 ADR-026：**

- ADR-026 负责“一条消息能否完整交付”：48 KiB 预算、zstd、`payload_too_large`、`tail_expired`、唯一发送缝。ADR-027 只负责“这条消息里应该有哪些字段”。两者不互相替代。
- 投影后仍必须经过 `_encode_document`/`_send_payload`；`_send_summary` 的“去 `fields` 再重试一次”回退保持不变。
- 投影可能改变压缩率（删除重复账本/成交行后，剩余市场行的压缩比可能变差），因此实现切片必须重跑 ADR-026 验收 1/3/4/5，并新增“每角色投影”的字节断言。
- ADR-026 验收 2 的“还原等价”在成员路径上改为“公开字段 + 本人私有字段等价”；完整文档等价只保留给磁盘/权威夹具。这一改写应回写到 ADR-026 的关联说明或实现记录。
- R18 仍可能因公开市场行超 48 KiB 而触发压缩/拒绝；R19 不承诺把文档压到 48 KiB 以下。

**与 ADR-019：**

- ADR-019 决定“谁能提交什么、身份从哪里来、扫描何时运行”；ADR-027 决定“提交结果谁能看见”。权限表、`execute_for_member` 的 actor 解析、`FarmCommand` 校验、扫描顺序、`pay_seq`/幂等窗口都不变。
- ADR-019 §3“经济提交后广播摘要”保留；只是摘要内容按收件人投影。`execute_for_member` 已只回本人 `bags`（568–571），这是本裁决的既有先例，继续保留。
- 市场订单/成交/物流的公开部分由 ADR-011/012/013 定义；ADR-027 只移除无 UI 需求的原始身份与账本，不隐藏交易对手需要看到的价格/方向/数量/状态。
- 访客仍无经济命令（ADR-019 §2）；投影不给访客开户/贷款数据。匿名成员仍无经济身份；投影的私区块为空。

### 9. 替代方案

| 方案 | 结论 |
|---|---|
| A. 逐 peer 投影（采纳） | 复用现有 seam，无新消息、无额外请求、无陈旧窗口；大型世界 CPU 线性放大，保留 B 作为触发后方案。 |
| B. 公开摘要 + 本人按需私有摘要 | 不采纳；需要新请求/合并状态机，收款人和贷款人有陈旧窗口。触发条件见 §12。 |
| C. 继续发送全量，只在 UI 层匿名 | 拒绝；原始 id、账本、经济命令载荷仍过线，R19 原样存在，且任何客户端都能读。 |
| D. 加密/独立隐私通道 | 拒绝；当前的威胁模型是“成员不应收到不需要的数据”，不是“服务器不可信”；加密不减少暴露面，反而增加密钥管理。 |
| E. 只裁 `bags` | 拒绝；账本 141,347 B、其他账户/贷款/订单身份仍在；R19 的“完整经济账本”部分未解决。 |
| F. 把经济整块删除、市场/银行每次按需拉取 | 可作为 B 的远期形态；当前会让市场/银行面板多一层请求与陈旧窗口，且需要新消息类型，超出最小完整方案。 |

### 10. 拍板结果（2026-11-15）

1. **订单/发货/交付/贷款的所有者按 `owner_scope` 匿名。** 线上只发 `me|merchant|other`，不发原始 id；现有“我/商人/他人”文案不变。
2. **他人贷款行不下发。** 只发本人合同行与银行聚合 `outstanding/fees`；银行面板列出本人合同即可，`repay` 按钮本就只对本人出现。理由：本金、费用、到期时间是借款人的私有经济信息，R19 的“最小暴露”优先于“列表更长”。
3. **经济命令在 `change`/`catch_up` 中一并去载荷。** 改为不透明占位 `{sequence, kind:"economy"}`，保留序号连续性；`pay` 金额、贷款本金不再经事件通道广播。不做这项，R19 不能关闭。

### 11. 未覆盖

- 本文是设计裁决，未写代码；没有任何投影实现、字节测量或测试运行。
- `Economy.valid_view` 的完整字段级校验、`FarmState.restore_view` 的具体归一化步骤未写成代码；实现时需保持“投影不可写回权威”的边界。
- 未测量投影后空/普通/上限世界的压缩率；删除重复账本可能降低压缩比，必须实测而不是沿用 ADR-026 的 18,679 B。
- 未逐一审计所有 UI（社交面板、启动场景、房间面板）；本文只覆盖共享世界客户端的主要消费点。并发工作树中的 R20 限频/房间改动不影响本裁决的字段结论，但可能移动行号。
- 未在 Windows、真实 WSS 多成员会话或移动端验证。
- 未确认 `command_results` 在每条客户端路径上都是必需的；本文按“非经济命令已公开、经济命令不本地回放”的证据裁剪。若发现本地回放需要他人经济结果，应改为保留去身份的最小结果而不是恢复整表。
- 未验证第三方偷菜的本地回放在中性 `theft` 记录下与权威完全一致；本文接受“下一次摘要校正”的降级。
- 未覆盖恶意成员把自己的投影转发给第三方的合谋/转发风险；这属于社交层，不在传输投影能解决的范围内。

### 12. 复审触发条件

- 任何 UI 需要另一个玩家的原始 id、余额、账本、贷款身份或经济命令载荷；届时以新的白名单 ADR 增补，不直接恢复全量广播。
- 成员规模或广播频率使逐 peer 投影的 CPU/分配/带宽成为瓶颈（例如 32/64 人世界、每秒经济扫描），则评估方案 B 或“公开广播 + 定向私有更新”。
- ADR-026 的 48 KiB 预算、压缩阈值或发送缝改变；或投影后的上限世界压缩后仍超预算。
- 农场/经济新增表（新的账户、订单、贷款、社交记录）或新增广播类型；字段矩阵必须同步。
- 社交功能开始向第三方展示访问记录、授权或被屏蔽关系；届时需单独裁决可见性，不能复用本 ADR 的“默认公开”假设。
- 真实 WSS 多成员会话出现与本地夹具不一致的交付/恢复行为。
