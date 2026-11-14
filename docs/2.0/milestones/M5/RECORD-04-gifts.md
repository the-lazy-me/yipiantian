# M5-04 · 玩家口袋与赠送（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M5 或 M5-02 验收完成。裁决：[ADR-005](../../decisions/ADR-005-player-bags.md)。前置：[M5-01 社交](RECORD-01-social.md)、[M5-02 协作授权](RECORD-02-grants.md)、[M5-03 邻里面板](RECORD-03-ui.md)、[M4-06 客户端](../../milestones/M4/RECORD-06-client.md)。

## 问题

M5-02 的“赠送”一直没有实现，原因是世界只有一份公共 `inventory`：收成不属于任何人，赠送只能把菜从一个公共格子挪到另一个公共格子。协作授权（RECORD-02）只解决了“谁能对哪块地做什么”，没有解决“收成是谁的”。

## 实现

### 归属：每个玩家一个口袋

- `FarmState` 的文档新增 `bags: {player_id: {crop_id: int}}`，与 `inventory`、`harvested` 同一次落盘。
- **具名收获**进入执行者的口袋；匿名成员、单人游戏与无头命令继续进公共 `inventory`，既有行为逐字不变。
- 上限检查按“这次实际入账的那一格”判断：口袋满了拒绝，公共库存满了也拒绝。
- 旧快照没有 `bags` 时恢复为空表；存在时严格校验（合法 ID、已知作物、非负整数），不合法整份拒绝，不做部分恢复。

### 赠送

- 命令：`{kind: "gift", id, to_id, crop_id, amount, at_utc}`，`amount` 为 1–99 的整数。
- **发送方只由权威按连接解析**（`WorldHost.execute_for_member` 从 `_players` 取 ID），命令里带 `from`/`from_id` 直接判为非法命令；客户端不能替别人送礼。
- 扣除与入账在同一次 `_data` 修改里完成，由 `FarmStore` 一次提交落盘：不存在扣了没入账的中间状态。
- 幂等沿用既有事务账本：同一命令 id 重放返回原结果 `duplicate=true`，不重复转移；同 id 不同载荷返回 `command_conflict`。赠送的事务载荷绑定权威解析出的发送方，换一个玩家 ID 拿同一 id 重放会被拒绝。
- 赠送对任何具名成员开放，不受田地 role/grant 限制（它不操作土地）；匿名成员没有口袋，返回 `no_player`。
- 失败路径具名且不改状态：`invalid_player`（自己送自己、ID 非法）、`invalid_crop`、`invalid_amount`、`insufficient`、`inventory_limit`。

### 客户端

- 重放使用同一个执行者（`remote.player_id`），所以本地镜像里收成也进自己的口袋，不会与权威各记一本账。
- 邻里面板新增“送一份收成”：只列自己口袋里有的作物与数量，联系人作为收件人，数量固定 1；空口袋时按钮禁用并说明原因。
- 送出后 `command_result` 的回复带上发送方自己的口袋余额，面板据此刷新；收礼一方在 `change` 广播里重放同一条命令，本地口袋同步增加。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 120 "$GODOT" --headless --path Game \
  --script "$PWD/tests/player_bags_test.gd"
perl -e 'alarm shift; exec @ARGV' 90 "$GODOT" --headless --path Game \
  --script "$PWD/tests/social_panel_scene_test.gd"
perl -e 'alarm shift; exec @ARGV' 240 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_client_scene_test.gd"
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m5_gift_test.gd"
```

结果：`PLAYER_BAGS_TEST checks=114 failures=0`；`SOCIAL_PANEL_TEST checks=27 failures=0`；`M4_CLIENT_SCENE_TEST checks=21 failures=0`；`M5_GIFT_TEST checks=37 failures=0`。回归 `FARM_STATE_TEST 385`、`FARM_COMMAND_TEST 45`、`WORLD_PACKAGE_TEST 112`、`V27_IMPORTER_TEST 68`、`WORLD_TRANSFER_TEST 75`、`WORLD_SNAPSHOT_TEST 28`、`M4_SYNC_TEST 39` 均为 `failures=0`。

CI 的干净检出只有 LFS 指针、没有导入后的美术，面板等场景套件在那里会打印 `skipped=no-art`（见 [M0 跨平台规则](../../milestones/M0/RECORD-06-cross-platform-rules.md)）。`player_bags_test`、`m5_gift_test` 不预加载美术，两平台照常执行：[runs/43647318235](https://github.com/the-lazy-me/yipiantian/actions/runs/43647318235) 上两者分别为 114 项与 37 项、`failures=0`。

| 用例 | 实际观察 | 结果 |
|---|---|---|
| 具名收获 | 收获进入该玩家口袋，公共 `inventory` 不变 | 通过 |
| 匿名/单人收获 | 行为与改动前完全一致，进公共库存 | 通过 |
| 口袋隔离 | 两个玩家的口袋互不影响 | 通过 |
| 赠送守恒 | 发送方 -1、接收方 +1，总量不变 | 通过 |
| 拒绝路径 | 余额不足、数量 0/负/超上限、未知作物、自己送自己、非法 ID 各自具名拒绝，状态不变 | 通过 |
| 幂等 | 同一命令 id 重放 `duplicate=true` 且不重复转移；同 id 不同载荷 `command_conflict` | 通过 |
| 落盘 | `FarmStore` 往返后口袋不丢；缺 `bags` 的旧快照可恢复 | 通过 |
| 摘要/快照 | 两者都携带口袋 | 通过 |
| 权限 | `WorldHost` 对访客的赠送放行；匿名成员被 `no_player` 拒绝 | 通过 |
| 面板 | 空口袋不提供选项；只列有存货的作物与数量；一次点击只发出一个“送 1 份给某人”的意图 | 通过 |
| 客户端重放 | 联机收获后本地口袋与权威一致（不漂移到公共库存） | 通过 |
| 真实会话赠送 | 甲（小满）收获后送出 1 份：`duplicate=false`，甲袋 0、乙袋 1；同 id 重放 `duplicate=true`、序号不前进；送完再送 `insufficient`；乙全程在线收到带 `from_id` 的广播，重启恢复后乙袋仍为 1、甲袋仍为 0 | 通过 |

真实会话用例为 `tests/m5_gift_test.gd`：父进程起隔离目录与证书，宿主进程运行 `WorldHost`，甲、乙经真实 WSS 会话加入，共 37 项检查。

## 未覆盖

- **收件人存在性**只校验 ID 格式：格式合法但从未出现过的玩家会得到一个离线口袋。严格拦截需要在权威侧对照名册/社交记录。
- 匿名成员能干活但不能收礼：他们的收成永远进公共仓库。这是 ADR-005 记录过的边界。
- 公共仓库（`inventory`）目前没有消耗方（厨房与动物在联机模式下被禁用），因此它只会由匿名劳动增长；引入市场（M7）前需要决定公共库存的用途。
- 口袋没有界面总览（“我的收成”只在送礼选择器里可见），也没有批量赠送、留言附言或退回。
- 上位限按作物计数，不按价值；礼物不可撤销。
- 只测回环；跨平台与真实局域网未验证。
- 旧的单人存档带 `bags` 后写入新格式；不承诺旧版本客户端能读回。

## 关联

- 裁决：[ADR-005](../../decisions/ADR-005-player-bags.md)。
- 协作授权：[RECORD-02](RECORD-02-grants.md)；社交与面板：[RECORD-01](RECORD-01-social.md)、[RECORD-03](RECORD-03-ui.md)。
- 客户端入世：[M4-06](../../milestones/M4/RECORD-06-client.md)。
