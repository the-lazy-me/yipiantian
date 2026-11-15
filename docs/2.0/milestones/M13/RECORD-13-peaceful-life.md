# M13-13 · 无联网、无云 AI、不参战的完整生活证据夹具

状态：已执行（2026-11-16），未验收。范围：新增 `tests/peaceful_life_test.gd`，在一个新建临时世界目录里用固定种子与固定逻辑时钟，证明一名玩家离线、不开模型、不参与冲突也能走完一条完整生活链，并在保存→重开同一目录后保持口袋、现金、建筑、挂单与账本一致。本切片只新增测试与本文档，未修改生产代码。

前置：[M13-05 PLAN](PLAN.md) 验收条款、[M13-01 规则链](RECORD-05-chain.md)、[M13-10 冲突链](RECORD-10-chain-conflict.md)、[M13-02 长期模拟](RECORD-11-long-simulation.md)。

## 要回答的问题

M13-05 的验收条款要求「不联网、不用云 AI、不参战仍完整生活；所有平台承诺有实际证据」。已有夹具回答的是别的问题：

- `chain_integration_test.gd`（M13-01）证明规则链的资产可追溯与守恒，它刻意跳过生活可达性，且大量使用市场卖单/物流/贷款逾期/地籍查询。
- `chain_conflict_integration_test.gd`（M13-10）证明参与制度、交战、组织基金与公共项目，正是「参战」路径。
- `long_simulation_test.gd` / `long_soak_test.gd` / `resident_long_run_test.gd` 证明长期数值稳定，不证明「离线单人仍能生活」。

本夹具只回答验收条款本身：同一进程内没有网络对象、没有模型、没有冲突文档，一名玩家把播种、成熟、收获、做饭、分享、本地成交、银行借贷、建造宅基与重启做完，并逐项断言守恒与持久化。

## 边界

- 单进程、无头、无场景、无 autoload、无 socket。`WorldClient` / `WorldHost` / `WorldServer` / `WorldMember` 与 AI 三个脚本一律不加载。
- 一个世界、一个固定 seed（`101507`）、一个固定逻辑时钟（`START = 1800014400`），时间只通过 `HeadlessWorld.advance_to` 前进。
- 第二个本地账户 `peace_b` 只用于让卖单成交，同一 `HeadlessWorld` 上一笔本地命令，不建连、不握手、不序列化。
- 目录为 `.local/verification/peaceful-life-<ticks_usec>/`，先写入固定 seed 再开世界。
- 不覆盖：UI/画面、Windows、真实墙钟驻留、真实跨机、多人并发、存档格式迁移。

## 覆盖与断言

### 1. 环境（每次运行在开局与结束各检查一遍）

- `SceneTree.multiplayer_peer` 必须是 `OfflineMultiplayerPeer`；`root` 下节点数为 0；`ProjectSettings` 里 `autoload` 为空。
- 对 `FORBIDDEN_RESOURCES` 逐个用 `ResourceLoader.has_cached()` 断言未加载：`world_client.gd`、`world_host.gd`、`world_server.gd`、`world_member.gd`、`model_scheduler.gd`、`llama_cpp_backend.gd`、`model_task.gd`。
- 扫描 `res://world/headless_world.gd` 的传递 `preload` 闭包（本次 64 个脚本），断言其中不含网络/AI 片段；同时断言夹具自身的脚本常量里没有这些模块。
- 两条**负向控制**，防止断言恒真：
  - 先断言 `has_cached("res://world/headless_world.gd")` 为真——本夹具自己 preload 了它；若探针失灵，这条会失败。
  - 向测试目录写入一个只有 `preload("res://world/world_host.gd")` 的合成脚本，闭合扫描必须恰好命中 1 个违规，然后删除该文件。

### 2. 居民与模型关闭

- `world.residents_enabled == false`，`residents_view().available == false`。
- `settle_residents(START)` 返回 `ok=true reason=disabled changed=false`，`intents` 为空。
- 重启后仍为关闭；`economy_snapshot().accounts` 中没有任何 `npc_` 开头的账户，即居民从未开户。

### 3. 和平

- `participation_view().available == false`，`participation` 保持 hostless 空表；`conflicts.consumed` 为空；`conflicts_view()` 的 sequence/targets/recent 全为 0。
- `units_view().units` 为空，即从未招募。
- 重启后 `participation.json`、`conflicts.json`、`units.json`、`residents.json`、`npc_residents.json`、`organizations.json`、`public_funds.json`、`public_works.json` 均不存在；`farm.json`、`nature.json`、`territory.json` 存在。

### 4. 生活链每一步

| 步骤 | 入口 | 结果 |
|---|---|---|
| 开世界 | `HeadlessWorld.open` | `ok=true kind=created` |
| 居民结算 | `settle_residents` | `ok=true reason=disabled` |
| 播种 ×6 | `FarmCommand.make_sow` + `execute` | 6 次 `ok=true stage=committed` |
| 生长 | `advance_to(T_HARVEST)` | `ok=true`，6 格 `mature`，时钟精确到 `START+7200` |
| 收获 ×6 | `FarmCommand.make` + `execute` | 6 次 `ok=true stage=committed`，每格 1 篮，全部进入 A 的口袋 |
| 开户 A/B | `make_account_open` | 2 次 `committed`，各 120 COIN |
| 开市场 | `make_market_open` | `committed`，本地商人开盘，greens 买价 5 |
| 挂卖单 | `make_market_place sell` | `committed`，口袋 6→4，托管 2 |
| 本地买入 | `make_market_place buy`（B） | `committed`，`market_matched=1`；B 付 12，A 得 11，销毁 1 COIN 手续费；B 口袋 +2 |
| 做饭 | `FarmState.kitchen_action("start")` | `ok=true`，口袋 4→3，灶上 20 秒 |
| 收菜 | 推进到 `T_HARVEST+20` 后 `kitchen_action("collect")` | `ok=true`，成品 1 份 |
| 分享 | `kitchen_action("share", neighbor=willow)` | `ok=true`，成品 1 份转出，`shared=1` |
| 开银行 | `make_bank_open` | `committed`，资本 2000 |
| 借款 | `make_loan_borrow 100 / 604800` | `committed`，A 现金 +100，合同 `open` |
| 还款 | `make_loan_repay` | `committed`，合同 `repaid`，`paid=105` |
| 建造 | `make_build("yard_a","cottage")` | `committed`；地籍门禁把 `parcel_01` 判给 A（首次建造即认领），`building_state="building"` |
| 完工 | `advance_to(T_BANK+601)` | `ok=true`，`building_state="done"`，业主 A、蓝图 cottage |
| 留挂单 | `make_market_place sell price=9 qty=2` | `committed`，`status=open`，托管 2，口袋 4→1 |
| 保存 | `HeadlessWorld.save` | `ok=true` |
| 重开 | 同一目录 `open(..., WORLD_ID)` | `ok=true kind=loaded` |

### 5. 守恒

- 现金：`total_cash == issued`；`reconcile.ok`；`reconcile.total_cash == total_cash`；`reconcile.issued == issued`；`accounts + merchant + escrow + bank == total_cash`。在开户、成交、借款、还款、建造、挂单、重启各检查一次。
- 货物：逐商品 `produced + granted == bags + merchant + sell_escrow + transit + lost + kitchen`。口袋端**枚举快照里所有 `bags` 所有者加共享 `inventory`**，不写死账户名；`kitchen` 端从权威厨房文档推导（`records[recipe].made` 按 `last_crop` 计 + 非空工位各计 1），不是夹具记账。
- 重启后另外断言：`harvested`、`bags`、`buildings`、装饰文档、账本条数逐项与保存前一致；`FarmCommand.has_committed` 仍认 `peace_rest_greens`。

## 实际原始输出

本机无头运行（连续两次逐字节相同）：

```text
PEACEFUL_LIFE steps=32 checks=343 failures=0
```

退出码 0，343 条 `PASS`，0 条 `FAIL`。世界目录只产生 `farm.json`、`farm.backup.json`、`nature.json`、`territory.json`。

## 还没做到的部分

1. **做饭与分享没有权威命令入口。** `FarmCommand.KINDS` 里没有厨房动作，`WorldHost.execute_for_member` 也不转发；厨房只由 `Game/scenes/main.gd::_kitchen_action` 在本地场景直接调用 `FarmState.kitchen_action` 后落盘。本夹具复现的是同一真实规则 + 同一 `FarmStore.save_state` 边界 + `farm.accept`，不是伪造成功，但它不是一条**网络权威可达**的路径。结论应写作「规则可达、权威入口缺失」：离线单人（本地存档）可完整生活，联机世界里的成员无法做饭。
2. **进食仍只是「把一篮菜做熟并送出」。** 没有饥饿、饱腹或必须进食的规则模块：全仓库搜 `hunger/hungry/meal` 只命中邻里故事文案、装饰的 `shared_meals` 解锁条件，以及 `NpcInvitation.KIND_MEAL`（一种邀约种类，不消耗货物）。因此「消耗至少一份」在本仓库里唯一真实形态就是厨房消耗，本夹具按此执行，不另造语义。
3. **地籍门禁只拦建造，不拦其他动作。** `may_build` 用于 `execute` 的 BUILD 事务；通行/越界查询另有入口但未在本夹具的和平生活链上出现。
4. **仅本机 macOS 无头。** 未在 Windows、真实窗口、真实墙钟、真实长驻留下重跑；「所有平台承诺有实际证据」中的平台部分仍未满足。
5. **CI 未登记。** 本切片未改 `.github/`，`peaceful_life_test` 尚未进入 `rule-tests.yml` 的测试列表，需要主会话统一加入后才成为自动门禁。
6. **未覆盖多人同世界的离线语义。** 夹具里第二个账户只是本地对手方，不涉及真实成员加入、授权与摘要同步。

## 发现

未发现使生活链断裂的生产缺陷。唯一结构性问题即上面第 1 条：厨房/进食缺少权威命令，属于**功能缺口**而非回归。若后续要修，最小方案是在 `FarmCommand` 增加 `kitchen` 一种命令（携带 `action`/`request`/`revision` 与幂等 id），并在 `_apply` 里调用既有 `state.kitchen_action`，权限按 `WorldInvite.allows` 与建造同档处理；本切片按要求未改生产代码。
