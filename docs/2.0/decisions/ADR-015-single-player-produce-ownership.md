# ADR-015 · 单机产出归属本机玩家口袋

- 状态：采纳（2026-11-15），M7-07 实现完成；旧档共享库存不迁移
- 关联：[M7-07 记录](../milestones/M7/RECORD-07-pantry-ownership.md)、[ADR-005](ADR-005-player-bags.md)、[ADR-010](ADR-010-economy-initial-conditions.md)、[ADR-011](ADR-011-market-orders.md)、[M7-06](RECORD-06-market-panel.md)

## 背景

M7-06 记录了一个阻塞：单机收获仍进入共享 `inventory`，而市场卖单、发货、厨房和动物中的具名玩家只读取或只应读取 `bags[本机玩家]`。结果是玩家能看报价、下单与发货，却没有可交易的货物；厨房与动物读到的也不是“自己的存粮”。M7-05 的供需实验因此只能用合成前提。

这是产品裁决，不是兼容性问题：单机里只有本机玩家，产出应当归到本机玩家的口袋，市场、厨房、动物与邻里篮子必须看到同一份食物。

## 决定

### 1. 口袋是具名玩家食物的唯一入口

- `FarmState` 新增非持久运行时字段 `pantry_owner` 与 `pantry()`。
- `pantry_owner` 是合法所有者 id 时，`pantry()` 返回 `_data.bags[pantry_owner]`；首次访问缺少该袋时创建空袋再返回。否则返回共享 `_data.inventory`。
- `kitchen_action`、`animal_action`、`share_basket`、`claim_gift` 内部统一使用 `pantry()`。
- 单机主场景的 tool command 路径把 `local_player_id` 作为 actor 传给 `farm_commands.execute`；因此具名收获进入 `bags[本机玩家]`。远程路径的 actor 仍由权威连接决定，不改为本地 id。
- 主场景在加载／恢复农场后设置 `pantry_owner`；非法的 `local_player_id` 留空。

### 2. 视图上下文不进入持久化

`pantry_owner` 只描述“当前视图读谁的口袋”，不是玩家数据：

- 不进入 `snapshot()`、JSON 或农场文档，不新增持久顶层键；
- `copy()` 带上 `pantry_owner`，候选事务与调用者读取同一口袋；
- `accept(candidate)` 保留活状态自己的 `pantry_owner`，避免权威摘要或候选覆盖本机视图。

保存路径继续使用 `snapshot()`。显示用的 `snapshot()` 由主场景 `_display_state()` 包一层：把 `inventory` 换成零值作物表叠加 `pantry()`，只为 UI 提供与旧共享库存同形的视图，不把视图写回存档。袋子本体仍按既有稀疏形状保存，读取缺失作物按 0 处理。

### 3. 匿名模式回退，旧档不迁移

- 没有合法本机玩家 id 的无头入口、旧命令路径与联机匿名成员保持匿名行为：收获进入共享 `inventory`，厨房、动物与篮子读取该库存。
- 旧存档已有的共享 `inventory` 原样保留；不删除、不搬移到 `bags[本机玩家]`、不新增迁移分支。新收获从本版本起进入口袋，旧库存对具名玩家不可见（共享库存仍对匿名路径可用）。

## 结果

- 单机第一次具名收获后，市场卖单／发货、厨房、动物喂食与邻里篮子都读取同一个 `bags[本机玩家]`。
- 市场交割、运输交付与礼物进入的也是该袋，因此单机生产—交易闭环不再缺货。
- 农场格式仍为 27；`_valid_snapshot`、`valid_cell_snapshot`、`V27Importer.KNOWN_FARM_KEYS` 未改。
- 旧档里仅存在于共享库存的存粮不会出现在新 UI 的口袋视图里，这是不迁移裁决的预期代价。
