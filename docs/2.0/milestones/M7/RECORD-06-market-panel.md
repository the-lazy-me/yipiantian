# M7-06 · 市场与物流玩家界面

状态：已实现（2026-11-15），未验收。范围：单机市场面板、钱包与报价视图、下单／撤单／发货／交付意图、主场景接线与共享世界只读。不包含网络命令权限、规则改动、美术资源、单机产出归属调整或 Windows 实机验证。

权威规则：[ADR-011](../../decisions/ADR-011-market-orders.md)、[ADR-012](../../decisions/ADR-012-matching-settlement.md)、[ADR-013](../../decisions/ADR-013-limited-logistics.md)；上层：[M7 PLAN](PLAN.md)、[经济与金融](../../systems/economy-finance.md)；前置记录：[M7-01](RECORD-01-economy-initial.md)～[M7-05](RECORD-05-supply-demand.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/ui/market_panel.gd` | 新增。钱包、六种商品报价与容量、订单与托管、发货／交付记录、下单与发货表单；只发出意图信号，不修改规则状态。 |
| `Game/scenes/main.gd` | 接线面板；单机首次打开时开户与商人开市；打开、刷新与每个命令后执行 `market_expire`／`market_match`／`market_deliver` 权威扫描；失败只更新文案并保留余额；共享世界只读；面板打开期间屏蔽世界输入。 |
| `Game/scenes/farm_hud.gd` | 底栏新增文字按钮「市场」与 `market_requested` 信号。 |
| `Game/scenes/startup.gd` | 把启动场景已有的稳定玩家 id 传给主场景的 `local_player_id`。 |
| `tests/market_panel_test.gd` | 新增 31 项视图检查。 |

未新增规则、依赖、网络消息或美术资源；农场格式、市场规则与存档形状未改。面板复用现有 `FarmTheme` 与底栏样式，因此预载主题字体，只在有美术的环境执行。

## 行为

- 打开面板先跑到期、撮合与交付扫描，再显示规则此刻会给出的视图；订单的部分成交、到期货运因此能反映出来。
- 单机首次打开时，用固定命令 id 调用 `economy_open_account`（120 COIN）与 `market_open_merchant`（600 COIN），都是幂等耐久记录，重复打开不会二次发行。
- 下单、撤单、发货、交付成功后才重新取视图并保存；失败只显示中文原因，不乐观修改余额或列表。
- 共享世界面板只读，并显示「联机世界暂只读：市场命令尚未接入网络权限。」；权威摘要到达时若面板打开则刷新。
- Esc／右键关闭面板并恢复镜头与世界输入。

## 实测输出

```
MARKET_PANEL_TEST checks=31 failures=0
```

真实场景冒烟（`--path Game --audio-driver Dummy --quit-after 2400`）退出码 0，`STARTUP_COMPLETE`，无脚本错误；退出阶段的 `DummyShaderE`／`ObjectDB` 泄漏告警是强制退出的既有噪声，未据此宣称零泄漏。冒烟未做点击级市场操作，因此命令路径由视图夹具与规则夹具分别覆盖，没有端到端点击证据。

## 未覆盖与阻塞

- **单机可交易货物缺失（已解决）**：本切片时单机收获仍进入共享 `inventory`，市场卖单只读 `bags[本机玩家]`，正常单机流程无法完成一次成交。[M7-07 单机产出归属](RECORD-07-pantry-ownership.md)（ADR-015）随后让具名收获进入本机口袋并同步厨房／动物／篮子读取，[M7-08 商人流动性](RECORD-08-merchant-liquidity.md)（ADR-016）给商人一次性库存与滚动报价；完整单机闭环现由 [M13 RECORD-13](../M13/RECORD-13-peaceful-life.md) 的 `PEACEFUL_LIFE_TEST` 端到端覆盖。
- **网络命令权限**：本切片当时不在 `FarmCommand`／WorldHost 角色权限表内。后续 [M4-09 经济命令](../M4/RECORD-09-economy-commands.md)（ADR-019）已把 `market_open`/`market_place`/`market_cancel`/`market_ship`/`market_deliver` 接进共享世界，`main.gd` 的联机分支发同一组命令；证据见 `M4_ECONOMY_COMMANDS_TEST`。面板上的「联机世界暂只读」文案不再出现。
- **美术与实机**：入口是文字按钮，没有图标、摊贩模型或 LFS 资源；未在 Windows 实机运行。
- **交互细节**：未做键盘全流程、手柄、数值输入边界与长列表滚动的实机验收；这些由视图夹具的按钮与信号断言代替。
- **真实玩家数据**：夹具与冒烟使用隔离目录/临时存档，没有使用真实存档。

## 双平台 CI

提交 `5b3959d` 的 [Rule fixtures 43680643834](https://github.com/the-lazy-me/yipiantian/actions/runs/43680643834) 两平台均通过（macOS 3m19s，Windows 3m12s）：

```
macOS   market_matching_test  MARKET_MATCHING_TEST checks=224 failures=0
macOS   market_logistics_test MARKET_LOGISTICS_TEST checks=174 failures=0
macOS   market_panel_test     skipped=no-art
macOS   rule fixtures: 56 listed, 7 skipped for missing art
Windows market_matching_test  MARKET_MATCHING_TEST checks=224 failures=0
Windows market_logistics_test MARKET_LOGISTICS_TEST checks=174 failures=0
Windows market_panel_test     skipped=no-art
Windows rule fixtures: 56 listed, 7 skipped for missing art
```

干净检出只有 LFS 指针，`market_panel_test` 预载主题字体，因此在两个平台都按 `skipped=no-art` 跳过；它不是静默通过，日志逐项点名。

## 待补证据

- 单机成交闭环需要先解决上面的归属或流动性裁决。
