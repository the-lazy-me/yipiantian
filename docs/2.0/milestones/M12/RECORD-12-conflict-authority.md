# M12-03 · 交战权威接入（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M12-03 或 M12 验收完成。前置：[M12 PLAN](PLAN.md)、[RECORD-03 · 交战与转移](RECORD-03-settlement.md)、[RECORD-07 · 单位交战损失桥接](RECORD-07-unit-conflict.md)、[RECORD-09 · 参与制度接入世界权威](RECORD-09-participation-authority.md)、[RECORD-06 · 单位接入世界权威](RECORD-06-unit-authority.md)。

## 问题

纯规则已经能结算一次交战（`ConflictSettlement.settle`）并把损失映射到进攻方单位（`UnitConflict.engage`），但世界权威还没有真实交战入口：没有持久化上下文、没有资源转移、没有玩家权限、没有重试恢复。直接把规则接到网络会让战利品可重复发放或让半提交的资产无法恢复。

## 边界

- 新增 `Game/world/conflict_store.gd`（`conflicts.json` sidecar）与 `tests/conflict_authority_test.gd`。
- 修改 `Game/world/headless_world.gd`（加载、视图、`execute_conflict`、真实资产提交与恢复）、`Game/world/world_host.gd`（RPC 19/20、权限）、`Game/world/world_member.gd` 与 `Game/world/world_client.gd`（客户端入口与预算解码）。
- 未修改 `Game/conflict/*` 纯规则、农场存档格式、参与制度规则、`Game/ui/*`、场景、协议版本或既有文档。
- 农场存档仍为版本 27；`PROTOCOL_VERSION` 仍为 1。

## 持久化

`conflicts.json` 信封：

```text
{version: 1, state: <ConflictSettlement 上下文>, applied: {<command_id>: <恢复元数据>}}
```

- `state` 是规则自己的上下文；`applied` 只是存储层恢复元数据，不进入 `state`，视图也不下发。
- 缺失：返回带 `world_id` 的空上下文，`participation` 故意留空，交战前由权威实时参与文档覆盖；空上下文可保存（首次交战才创建目标行）。
- 损坏 / 版本不支持 / 异世界：分别返回 `corrupt` / `unsupported` / `world_mismatch`，权威拒绝启动且不覆盖原文件。
- 文件上限 1 MiB；pending 写入、回读逐字节校验、rename。

## 提交顺序与恢复

正常提交（每一步各自落盘）：

1. 校验请求形状、单位归属、防御者身份、坐标与地块；把实时的参与文档覆盖进上下文副本；首次出现的目标建立 `defender|parcel` 预算行并应用固定上限。
2. `at_utc` 取权威时钟；现金与物资完全从农场读取；调用 `UnitConflict.engage()`（纯规则未改）。
3. 保存冲突意图：`next_context` + `applied[command_id] = {applied: false, signature, unit_plan}`。
4. 农场候选：按 `EconomyCatalog.goods_ids()` 顺序扣进攻方 `supply_cost`、扣防守方 `taken_supplies`、加进攻方 `spoils_supplies`；`conflict_take_*` / `conflict_spoil_*` 现金转移；写盘前校验 `total_cash == issued`、双方物资前后值、双方现金+物资合计减少量 `== destroyed`；保存成功后替换活农场。
5. 保存单位文档并替换内存。
6. 保存 `next_context.participation` 并替换实时参与文档。
7. 保存冲突文档 `applied = true`（移除 `unit_plan`，保留签名）。

重试：

- 同编号同签名且 `applied=true`：直接 `duplicate=true`，不读资产、不写盘。
- 同编号同签名且 `applied=false`：按现金账本标记、物资 post/pre、单位计划前后人数、参与耐久交战行判断哪些步骤已经完成，只补齐缺失步骤；任一侧证据矛盾返回 `stale_resources` / `stale_participation` / `invalid_units`，绝不重放。
- 存在未完成提交时，新命令返回 `recovery_required`。
- 防守方现金为 0、没有现金分录时，改由物资前后值判断农场是否已提交；现金与物资证据矛盾时拒绝。
- 多单位战损中未变化的单位在计划里视为中性，不作为“已写/未写”证据。

## 目标上限

参与制度的 `loss_cap` 按窗口累计；跨窗口反复袭击仍需要权威侧总量上限。本切片为每个 `defender|parcel` 目标固定 `CONFLICT_TARGET_LOSS_CAP = 100`，客户端不可指定；达到上限后下一次交战返回 `target_cap`，文档与资产不变。近期结果最多保留 20 条。

## 事件的守恒口径

实现的是“双方现金 + 物资合计减少量 == `destroyed`”，并额外保证 `total_cash == issued`。分项为：

- 进攻方现金 `+ spoils_cash`，物资 `- supply_cost + spoils_supplies`；
- 防守方现金 `- taken_cash`，物资 `- taken_supplies`；
- `destroyed = supply_cost + losses - spoils`（`losses = taken_cash + taken_supplies`，`spoils = spoils_cash + spoils_supplies`）。

直接用 `destroyed - supply_cost` 对账会混淆现金战利品与防守方损失，测试按上面的分项断言。

## 视图与 RPC

`conflicts_view()`：

```text
{sequence, targets[{defender, parcel_id, losses, cap}], recent[{...}]}
```

- 目标按 key 排序；`recent` 不含 `consumed` 的 payload/freeze，也不含完整 `outcome`。
- 读取（`state` / `view`）对已入册连接开放，包括访客与匿名成员；写（`engage`）要求 `MEMBER`、非只读、具名玩家。
- 防守者在线状态由成员表派生（`_player_peer`），客户端载荷不能指定。
- RPC 19 `conflict_request(payload)`、20 `_conflict_reply(request_id, payload)`；请求与答复共用 48 KiB `WorldPayload.WIRE_BUDGET_BYTES`，超限在 `rpc_id` 前换成可见的 `payload_too_large` 拒绝；交战与其它权威写入共用命令令牌桶。
- `WireMember` 频道 20 先 `Payload.decode` 再交给基类；客户端新增 `request_conflict()` 与 `conflict_result` 信号。

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/conflict_authority_test.gd"
```

原始末行：

```text
CONFLICT_AUTHORITY_TEST checks=276 failures=0
```

回归：`UNIT_AUTHORITY_TEST 146/0`、`PARTICIPATION_AUTHORITY_TEST 121/0`、`PUBLIC_FUND_AUTHORITY_TEST 211/0`、`M4_HOSTING_TEST 25/0`、`TERRITORY_AUTHORITY_TEST 69/0`。

覆盖：

| 范围 | 断言 |
|---|---|
| 存储/加载 | 空上下文、空上下文可保存、1 MiB、损坏、版本不支持、异世界、无房主 `no_host` 且不生成文档 |
| 和平档 | `peace` 拒绝，四份文档字节不变，现金不变 |
| 真实结算 | 20 兵对 14 可损失：`losses=14`、`taken_cash=4`、`taken_supplies=10`、`spoils_cash=2`、`spoils_supplies=5`、`supply_cost=20`、`destroyed=27`、目标 14/100 |
| 资产结果 | 进攻方现金 +2、物资 -20+5；防守方现金 -4、物资 -10；`total_cash==issued`；进攻单位 20→6，防守单位不变；参与损失 14；单位文档持久化 |
| 视图 | 目标排序；近期结果不含 payload/freeze；上下文通过 `valid_context`，`applied=true` |
| 幂等 | 同编号同载荷 `duplicate=true`，四份文档、现金、物资、参与损失、上下文完全不变 |
| 换载荷 | 坐标/单位列表/地块/防御者变化均 `command_conflict`，文档字节不变 |
| 目标上限 | 50+50 达到 100；第三次 `target_cap`，无字节/物资/单位变化 |
| 具名拒绝 | `insufficient_supply`、`insufficient_resources`、双方 `empty_units`、同列表与跨列表 `duplicate_unit`、`not_owner`、`unknown_unit`、`same_player`、`invalid_defender`、负坐标与超界坐标、`invalid_target`、未同意 `no_consent` |
| 权限 | visitor 可读不可写、匿名 `no_player`、只读 `read_only`、未知动作、非成员 |
| 重启 | 上下文、applied 标记、目标 14、参与损失 14、单位 6、现金/物资全部保留；同编号重试为 duplicate，不二次发放战利品 |
| 恢复 A | 农场保存失败：`save_io`，农场字节不变，意图 `applied=false`，单位未减；重试只补缺失步骤，现金 82/0、物资 165/0、单位 6、参与 14，且仅一次 |
| 恢复 B | 单位保存失败：`save_units_io`，农场已提交；重试不改农场字节，只补单位与参与，`applied=true` |
| 恢复 C | 防守方现金 0、多单位（2/2/100）：无现金分录仍可恢复；损失 10 后单位 1/2/91；物资 196/10→97/0 仅一次 |

## 未覆盖

- 真实网络传输：RPC 19/20 的编解码、48 KiB 超限、令牌桶与真实 peer 权限只做了接线与直连权限断言，没有真实 WSS 测试；下一步补 `tests/conflict_network_test.gd`。
- 未直接模拟的崩溃点：参与文档已写、`applied=true` 未落盘；最终 `applied=true` 保存失败；意图落盘后、农场落盘前外部命令改变农场；农场提交后参与文档又被改写。恢复逻辑有对应分支，但没有专门夹具。
- `capacity`（目标表满）、`invalid_command`、`invalid_context`、`save_conflicts_*` 失败、结算后外部改动导致 `insufficient_cash` 等分支。
- 多商品物资只验证了单商品夹具；代码按目录顺序执行，未逐一断言商品顺序。
- 战利品物资固定加入目录第一项商品，是确定性设计。
- 网络答复只含 `state.recent` 摘要，不含完整 `outcome`；UI 若需要完整战报需扩展答复。
- 交战 UI、行军、战斗动画与战后历史不在本切片内。

## 关联

- 规则：[RECORD-03 · 交战与转移](RECORD-03-settlement.md)、[RECORD-07 · 单位交战损失桥接](RECORD-07-unit-conflict.md)。
- 依赖：[RECORD-09 · 参与制度接入世界权威](RECORD-09-participation-authority.md)、[RECORD-06 · 单位接入世界权威](RECORD-06-unit-authority.md)。
- 阶段计划：[M12 PLAN](PLAN.md)。
