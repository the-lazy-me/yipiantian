# M4-12 · 摘要按收件人投影

执行日期：2026-11-15。状态：切片完成，不表示 M4 或 R19 验收完成。关联：[ADR-027](../../decisions/ADR-027-summary-visibility.md)、RISKS R19、[ADR-026](../../decisions/ADR-026-network-payload-limits.md)、[M4-11 限频](RECORD-11-rate-limit.md)。

## 背景

权威一直把完整 `FarmState`（含全部 bag、经济账户、账本、他人贷款行与经济命令结果）放进 summary/snapshot 广播给每个成员。ADR-026 只约束“一条消息多大”，ADR-027 决定“消息里有哪些字段”。本切片在唯一的发送缝按收件人投影，权威内存与存档不变。

## 实现

- `Game/world/world_projection.gd`（新增，纯函数）：`project_summary`、`project_snapshot`、`project_change`、`project_tail`。按 ADR §3 白名单保留公开字段；`bags`/`accounts` 只含本人；贷款只含本人合同；订单/发货/交付/贷款把 `owner`/`borrower` 换成 `owner_scope: me|merchant|other`；他人 `theft` 换成中性记录；删除 `ledger`、`conversion`、`trades`、`losses`、`economy.command_results`、`gift_ids` 与无消费方的归档计数。`snapshot.view = {version, viewer, role}` 标记投影。
- `Game/world/world_host.gd`：`_summary_document(peer_id)` 同时服务 `request_summary` 与 `_broadcast_summary`；`_append_tail`/`tail_since(since, viewer)` 先投影再按 48 KiB 预算度量；`catch_up` 传入连接解析出的身份。仍只走 `_encode_document`/`_send_payload`/`_send_summary`。
- `Game/world/world_member.gd`：`restore_state()` 看到 `view` 时校验版本与 viewer 并走 `FarmState.restore_view()`；无标记仍走 `restore_snapshot()`，旧权威文档与磁盘夹具不受影响。
- `Game/farm/farm_state.gd`：`restore_view()`、`has_bag()`、`economy_view_complete()`、`credit_view_bag()`、`_normalize_view_economy()`；`_valid_snapshot(data, view_economy, viewer)` 在视图模式下拒绝非本人 bag 与非中性他人 theft。
- `Game/farm/economy_state.gd`：`valid_view(state, viewer)` 只查形状、范围与 `owner_scope`，不做现金守恒与账本重放；投影文档不可能通过权威 `valid()`。
- 客户端降级：缺本人 bag 显示一次“个人资料同步中”；缺 accounts 表时市场/银行只读；撤单/还款只按 `owner_scope=="me"` 出现；银行聚合优先读投影里的 `bank.outstanding/fees`。投影不再带送礼者口袋，收到礼物时由 `credit_view_bag()` 只补收件人一侧。

## 验证

| 入口 | 结果 |
|---|---|
| `tests/world_projection_test.gd`（新增，164 项） | `WORLD_PROJECTION_TEST checks=164 failures=0`；上限世界 `PROJECTION_BUDGET raw=319632 wire=10926 compressed=true` |
| `tests/world_snapshot_test.gd` | `WORLD_SNAPSHOT_TEST checks=33 failures=0` |
| `tests/world_tail_test.gd` | `WORLD_TAIL_TEST checks=31 failures=0` |
| `tests/world_payload_test.gd` | `WORLD_PAYLOAD_TEST checks=67 failures=0` |
| `tests/world_rate_limit_test.gd` | `WORLD_RATE_LIMIT_TEST checks=21 failures=0` |
| `tests/m4_sync_test.gd` | `M4_SYNC_TEST checks=39 failures=0` |
| `tests/m4_client_scene_test.gd` | `M4_CLIENT_SCENE_TEST checks=40 failures=0` |
| `tests/m4_economy_commands_test.gd` | `M4_ECONOMY_COMMANDS_TEST checks=162 failures=0` |
| `tests/m5_social_test.gd` | `M5_SOCIAL_TEST checks=58 failures=0` |
| `tests/m5_gift_test.gd` | `M5_GIFT_TEST checks=38 failures=0` |
| `tests/m4_server_test.gd` | `M4_SERVER_TEST checks=79 failures=0` |
| `tests/village_beta_test.gd` | `VILLAGE_BETA_TEST checks=116 failures=0` |
| `tests/bank_panel_test.gd` / `market_panel_test.gd` | `BANK_PANEL_TEST 46/0`、`MARKET_PANEL_TEST 49/0` |

## 增补：地籍

2026-11-15 地籍可见性切片给摘要增加公开 `territory`（`{sequence, parcels:[{id, slot, owner, status, claimed_utc, rect}]}`），`claim_id` 不过线；`WORLD_PROJECTION_TEST` 扩到 172 项、`M4_CLIENT_SCENE_TEST` 扩到 42 项。详见 [M11 RECORD-03](../M11/RECORD-03-cadastre-visibility.md)。

## 增补：四个只读房间块

2026-11-16 摘要新增 `units`、`organizations`、`funds`、`public_works` 四个只读块，让客户端面板不必为显示名册单独走一趟 `state`。字段白名单、角色准入、16 KiB 配额与空形状语义见实现记录 [M13 RECORD-15](../M13/RECORD-15-default-summary-room-views.md)；本页只记这一点：它落在同一条 `project_summary()` 发送缝上，48 KiB 线路上限仍由 `WorldHost._encode_document()` 决定。

## 未覆盖

- 投影预算只测了 schema 上限世界（wire 10,926 B）；空世界与普通世界未单独记录。
- UI 降级的三种形态（缺本人 bag、缺 accounts、缺 `owner_scope`）已实现，但没有场景级夹具直接构造这些缺失文档；面板测试主要覆盖正常行。
- 第三方偷菜在中性记录下的本地回放只断言形状，未做与权威的端到端对比；按 ADR §11 接受“下一次摘要校正”。
- `PROTOCOL_VERSION` 仍为 1；旧客户端遇到投影文档会得到具名 `invalid_farm`/`view_version`，但未用旧构建实测。
- 未验证 32/64 人大小的逐 peer 投影开销；当前实现每个 peer 各构造一份 summary 与 snapshot。
- 未在 Windows、真实多机 WSS 或移动端验证。

## 关联

- 裁决与字段矩阵：[ADR-027](../../decisions/ADR-027-summary-visibility.md)。
- 载荷与发送缝：[ADR-026](../../decisions/ADR-026-network-payload-limits.md)、[M4-11](RECORD-11-rate-limit.md)。
