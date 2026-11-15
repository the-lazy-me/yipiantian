# M7-07 · 单机产出归属本机玩家口袋

状态：已实现（2026-11-15），未验收。范围：单机具名收获、厨房／动物／邻里篮子读取同一口袋、显示视图与保存视图分离、夹具。不包含旧档迁移、农场格式变更、网络权限或 Windows 实机验证。

权威决定：[ADR-015](../../decisions/ADR-015-single-player-produce-ownership.md)；前置记录：[M7-06](RECORD-06-market-panel.md)、[ADR-005](../../decisions/ADR-005-player-bags.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/farm_state.gd` | 新增非持久 `pantry_owner` 与 `pantry()`；`copy()` 带上上下文，`accept()` 保留活状态自己的上下文；`kitchen_action`／`animal_action`／`share_basket`／`claim_gift` 改用口袋；稀疏袋按 0 读取缺失作物。 |
| `Game/farm/kitchen.gd` | 原料检查改用 `inventory.get(crop, 0)`，与动物喂食的稀疏袋读取一致。 |
| `Game/scenes/main.gd` | 单机 tool command 传 `local_player_id`（仅合法时）；加载／恢复与联机摘要后绑定 `pantry_owner`；新增 `_display_state()`，所有显示用 `snapshot()` 改为口袋视图，保存继续用 `snapshot()`。 |
| `Game/presentation/garden_album.gd` | 相册／见闻刷新改用主场景的显示视图；拍照与保存仍用 `snapshot()`。 |
| `tests/pantry_test.gd` | 新增 54 项检查：归属、回退、厨房、动物、篮子、失败原子、copy/accept、JSON 与存档往返。 |

农场格式仍为 27；未新增持久顶层键，`_valid_snapshot`、`valid_cell_snapshot`、`V27Importer.KNOWN_FARM_KEYS` 未改。既有夹具未调整：它们没有设置 `local_player_id`，仍按匿名路径读取共享库存，断言没有被放宽。

## 行为

- 单机具名收获进入 `bags[本机玩家]`，共享 `inventory` 不再增加；匿名路径（无合法本机 id）继续写共享库存。
- 厨房、动物、邻里送篮与回礼读取并修改同一个口袋；市场卖单、发货、成交、交付与礼物本来就以 `bags[owner]` 为准，因此单机生产—交易闭环恢复。
- `pantry_owner` 只存在于内存，不进入 `snapshot()`、JSON 或农场格式；JSON 与存档夹具确认文档中没有该键。
- 显示视图把口袋叠加到零值作物表上，只为 UI 提供完整作物键；袋本体仍按稀疏形状保存，显示不写回存档。
- 旧档共享 `inventory` 原样保留，不迁移、不删除；新收获进入口袋。

## 实测输出

```
PANTRY_TEST checks=54 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/pantry-265691
FARM_STATE_TEST checks=385 failures=0
PLAYER_BAGS_TEST checks=114 failures=0
KITCHEN_STATE checks=347 failures=0
ANIMAL_COMPANIONS failures=0
NEIGHBOR_STATE_TEST checks=261 failures=0
ANIMAL_BEHAVIOR_PASS
ANIMAL_WEATHER_ROUTINE_TEST checks=30 failures=0
ANIMAL_MOTION_REGRESSION_PASS thin obstacle, 30/60/120 Hz turning and collision-free detour
```

主场景解析与启动冒烟（`--headless --audio-driver Dummy --quit-after 120`）输出 `STARTUP_COMPLETE`，无脚本解析错误。

场景／视图夹具：

```
MARKET_PANEL_TEST checks=31 failures=1
  ERROR: The bid shown is the one the market view carries
```

该项断言写死 `greens` 买价为 `4`，而同一轮 M7-08 已把商人报价改为参考价 ±1（`greens` 买价变为 `5`）。主会话把断言改成与 `view.quotes` 自身携带的 bid 比较，重跑 `MARKET_PANEL_TEST checks=31 failures=0`。

```
kitchen_scene_test        未在本机无头环境跑完（400s/560s 超时，无最终行）
neighbor_story_scene_test 2 项 Required story control missing（用 HEAD 主场景同样失败）
animal_contact_scene_test Actual animal click opens goose（用 HEAD 主场景同样失败）
```

前三项分别依赖点击／截图与美术，在本机无头渲染下会停在 `frame_post_draw` 或错过控件；用 `git show HEAD:Game/scenes/main.gd` 复跑邻居与动物场景得到同样的失败，因此不归因于本切片。

## 未覆盖

- 双平台 CI 已通过：提交 `ab1d97a` 的 [Rule fixtures 43684813326](https://github.com/the-lazy-me/yipiantian/actions/runs/43684813326) 两平台均为 `PANTRY_TEST checks=54 failures=0`，共 60 项夹具、7 项按 `skipped=no-art` 跳过。
- 真实存档未使用；夹具都在隔离目录生成临时存档。
- 旧档里只存在于共享 `inventory` 的存粮不会出现在具名玩家的口袋视图里，这是不迁移裁决的预期结果。
- 联机模式下市场命令仍受既有网络权限阻塞；本轮只让显示读取本机袋，不新增网络消息或权限。
- 场景夹具的点击与截图证据不完整：`kitchen_scene_test` 未产出最终行，邻居与动物场景夹具在本机无头环境的失败在 HEAD 主场景上可复现。
