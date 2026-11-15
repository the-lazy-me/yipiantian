# M11-03 · 地籍可见性与宅基面板

执行日期：2026-11-15。状态：切片完成，不表示 M11 验收完成。前置：[M11-02 地籍接入权威](RECORD-02-cadastre-authority.md)、[ADR-028 · 建造与地籍权限](../../decisions/ADR-028-build-land-authority.md)。

## 问题

ADR-028 让建造命令在权威侧按地块校验后，客户端出现了新的可用性缺口：宅基面板仍只显示空槽和蓝图，玩家要等到命令被拒绝才知道地块属于别人；首次建造隐式主张后，其他成员也要等到 30 秒 reconcile 才能看到新归属。本切片只补“看得到”，不新增主张/转让入口。

## 决定

### 1. 摘要携带公开地籍，投影按白名单放行

`HeadlessWorld.territory_display()` 把地籍整理成显示文档：

```text
{ sequence, parcels: [ { id, slot, owner, status, claimed_utc, rect } ] }
```

- `slot` 由 `TerritoryState.parcel_slot_id()` 反查（`parcel_%02d(i+1)` ↔ `Buildings.SLOTS[i]`），客户端不复制映射。
- `claim_id` 是内部命令 id，不进入显示文档；`WorldProjection._project_territory()` 再以白名单投影一次，即使它将来重新出现在 `summary()` 也不会过线。
- 归属（`owner`、`status`）是共同事实，公开；地块矩形是默认布局的占位坐标，不含私有信息。

### 2. 首次建造的主张随摘要广播，不做客户端本地回放

`HeadlessWorld` 的变更信号由 `economy_changed` 更名为 `shared_changed`：经济提交、结算变化与隐式土地主张都会触发 `WorldHost._broadcast_summary()`。提交者之外的所有成员随即收到按自己投影的摘要，不需要从 `change` 事件推导地籍；30 秒 reconcile 仍保留为兜底。

### 3. 宅基面板只显示归属，权威仍裁决

`main.gd::_parcel_views()` 把摘要映射为每个槽位的 `{label, blocked}`：

| 摘要状态 | 面板文案 | 建造按钮 |
|---|---|---|
| `unclaimed` | 无主宅基，第一次建造就归你 | 可用 |
| `claimed` 且 `owner == 本人` | 这是你的宅基 | 可用 |
| `claimed` 且他人 | 宅基属于 `<名册显示名或 player_id>` | 禁用，并给出“不能在别人的地上建房”的说明 |
| `public` | 公共宅基 | 可用 |

古老/缺失摘要没有 `territory` 时不显示地籍行，也不猜测归属。面板不因为摘要陈旧而改变命令语义：`build_gate` 仍是唯一裁决点，拒绝原因仍来自权威。

## 未覆盖

- 多成员同时打开宅基面板时的实时刷新只验证了“提交后摘要送达”，没有验证两个客户端同屏竞速。
- 主张、转让、释放仍无客户端入口；面板不提供“主张这块地”按钮。
- `state_snapshot()` 仍不含地籍（与 RECORD-02 一致）；掉线成员靠摘要恢复，不靠快照。
- 未在 Windows 实机或真实局域网双机验证；未验证公共地块的实际显示（当前没有生成 `public` 地块的命令）。

## 证据

| 测试 | 末行 |
|---|---|
| `world_projection_test` | `WORLD_PROJECTION_TEST checks=172 failures=0` |
| `build_panel_test` | `BUILD_PANEL_TEST checks=33 failures=0` |
| `m4_client_scene_test` | `M4_CLIENT_SCENE_TEST checks=42 failures=0` |
| `territory_build_gate_test` | `TERRITORY_BUILD_GATE_TEST checks=79 failures=0` |
| `m4_reconnect_test` | `M4_RECONNECT_TEST checks=31 failures=0` |
| `chain_integration_test` | `CHAIN_INTEGRATION_TEST checks=509 failures=0` |
| `world_payload_test` / `world_rate_limit_test` | `67/0`、`21/0` |

## 关联

- 前序记录：[M11-02 · 地籍接入世界权威](RECORD-02-cadastre-authority.md)。
- 裁决：[ADR-028 · 建造与地籍权限](../../decisions/ADR-028-build-land-authority.md) §8、[ADR-027 · 摘要可见性](../../decisions/ADR-027-summary-visibility.md) §3.2。
- 阶段计划：[M11 PLAN](PLAN.md)。
