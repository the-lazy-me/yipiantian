# M5-03 · 可选偷菜（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M5 或 M5-03 验收完成。前置：[M5-01 社交](RECORD-01-social.md)、[M5-02 协作授权](RECORD-02-grants.md)、[M5-04 玩家口袋](RECORD-04-gifts.md)。

## 问题

在玩家口袋（RECORD-04）之后，收成第一次有了主人，但“谁能收走它”还没有规则：任何具名成员都能收获任何成熟作物，收成直接进入自己口袋。协作授权只覆盖“房主明确授权”的一条路，默认状态下等于偷菜永久开启且没有上限，与[社会与住宅设计](../../systems/society-housing.md)“默认和平家园不开放偷菜”相反。

## 实现

### 归属：谁种的就归谁

- 播种时记录执行者：`sow(..., actor)` 把 `planted_by` 写进格子，具名成员种下的作物归自己。
- 匿名播种、初始作物与旧快照留下的格子没有主人（`planted_by` 为空），任何成员都能照旧收获，单人游戏与无头命令的行为逐字不变。
- 收获后格子清空，`planted_by` 一并清空；重新播种才产生新的主人。

### 默认关闭，按所有者开启

- 新的 `theft` 表：`{player_id: {enabled, day, lost, last}}`，与农场文档同一次落盘。
- 命令 `set_theft`（`{id, kind, enabled, at_utc}`）：执行者由权威按连接解析，命令里带 `from`/`from_id` 即非法；匿名成员得到 `no_player`。
- 收获别人的作物时：所有者未开启 → `not_owner`；当天已被拿走 `MAX_THEFT_PER_DAY`（3）份 → `theft_limit`；同一小偷距上次偷同一所有者不足 `THEFT_COOLDOWN_SECONDS`（600 秒）→ `theft_cooldown`。
- 允许时作物进入**小偷**的口袋，所有者当天的 `lost` 加一、`last` 记录时间；这些计数与收获在同一次 `_data` 修改里完成，拒绝则整条命令无副作用。
- 日切是惰性的：只有下一次偷取尝试才把 `day`/`lost` 归零，所以快照里的 `lost` 可能仍是前一天的数，直到有人再偷。

### 授权收获不是偷

- `harvest` 命令可带 `authorized` 标记。权威在每条收获命令上**按社交授权记录重新计算**它并写进广播的命令（客户端自称的值被覆盖），因此所有客户端重放时得到同一个结论。
- 带 `authorized` 的收获跳过偷菜限制：房主明确允许的协作收获仍然照旧进入收获者口袋（RECORD-02 的语义不变）。
- 幂等载荷只在 `authorized` 为真时追加该位，旧账本里已有的收获载荷继续按原样重放。

### 顺带修复：邻居广播用错了执行者

客户端重放邻居的 `change` 广播时用的是**本机玩家** ID，而不是广播里的 `from_id`。有口袋之后这会把邻居的收成记进我的口袋（本地镜像与权威分叉）；有偷菜规则之后，还会把“别人偷我的地”重放成“我自己收自己的地”，两边结论不同。现在按广播的 `from_id` 重放，匿名成员按匿名处理（进公共仓库），`M4_CLIENT_SCENE_TEST` 有三条断言守住这一点。

### 客户端

- 邻里面板新增“允许邻居偷一份成熟收成”开关，只表示意图：勾选发出一个 `set_theft` 意图，权威回执后才更新，面板不自行改变本地状态。
- 权威的社交回复带上本人的偷菜开关，面板据此回填，不用另开通道。
- 拒绝原因翻成可读文案：`not_owner`“这是别人种的，对方没有开放偷菜”、`theft_limit`“今天已经从这家拿走够多了”、`theft_cooldown`“刚取过一次，稍后再来”。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 120 "$GODOT" --headless --path Game \
  --script "$PWD/tests/player_theft_test.gd"
perl -e 'alarm shift; exec @ARGV' 90 "$GODOT" --headless --path Game \
  --script "$PWD/tests/social_panel_scene_test.gd"
perl -e 'alarm shift; exec @ARGV' 240 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_client_scene_test.gd"
```

结果：`PLAYER_THEFT_TEST checks=128 failures=0`（连续两次）；`SOCIAL_PANEL_TEST checks=34 failures=0`。回归 `FARM_STATE_TEST 385`、`FARM_COMMAND_TEST 45`、`PLAYER_BAGS_TEST 114`、`M5_GRANT_TEST 34`、`M4_ACTIVITY_TEST 18`、`M5_GIFT_TEST 37`、`M5_SOCIAL_TEST 52`、`M4_CLIENT_SCENE_TEST 27` 均为 `failures=0`。

CI：[runs/43647318235](https://github.com/the-lazy-me/yipiantian/actions/runs/43647318235)（macOS 与 Windows 均 success）。两平台都执行 `player_theft_test`（128 项）与 `m5_gift_test`（37 项）；场景套件因检出没有 LFS 美术而打印 `skipped=no-art`，见 [M0 跨平台规则](../../milestones/M0/RECORD-06-cross-platform-rules.md)。

| 用例 | 实际观察 | 结果 |
|---|---|---|
| 归属 | 具名播种后 `owner_of` 返回播种者；匿名播种为空 | 通过 |
| 默认关闭 | 他人收获未开启偷菜的作物得 `not_owner`，格子、口袋、`harvested`、序号都不变 | 通过 |
| 开关 | `set_theft` 前后状态改变；非法 ID 拒绝；匿名命令 `no_player` | 通过 |
| 开启后偷取 | 作物进小偷口袋、所有者 `lost` +1、格子清空、公共 `inventory` 不变 | 通过 |
| 每日上限 | 当天第 4 次被偷（4 个不同小偷）得 `theft_limit`，状态不变；跨 UTC 日后重置 | 通过 |
| 冷却 | 同一小偷立刻再偷得 `theft_cooldown`；推进 `THEFT_COOLDOWN_SECONDS + 1` 后允许 | 通过 |
| 授权收获 | `authorized = true` 且未开启偷菜仍能收获 | 通过 |
| 无主格 | 初始作物与旧快照格子任何成员可收 | 通过 |
| 幂等 | 同 id 重放 `duplicate=true`；同 id 改 `authorized` 或换执行者 `set_theft` 得 `command_conflict` | 通过 |
| 落盘 | `FarmStore` 往返后开关、计数、`planted_by` 保留；缺 `theft` 的旧文档可恢复 | 通过 |
| 面板 | 开关默认关闭；勾选只发出一个 `set_theft` 意图；权威回填不再重复发 | 通过 |
| 邻居广播 | 具名邻居的收获记进该邻居口袋、不进我的口袋；匿名广播进公共仓库 | 通过（`M4_CLIENT_SCENE_TEST`） |
| 授权收获 | `authorized = true` 且未开启偷菜仍能收获；权威在答复里带上该标记，被拒的命令不带 | 通过（`M5_GRANT_TEST`） |

## 未覆盖

- **带授权的他人网格收获在客户端的本地重放没有专门用例**：实现从答复与广播里取权威盖上的 `authorized` 再重放，但只有权威侧字段有断言。
- **偷菜没有专门的交互入口**：开启后，偷取就是收获别人的成熟作物，界面不标记“这是别人的地”。缺少“谁种了这块地”的可见提示、偷取提示与历史记录。
- 上限与冷却只按 UTC 日与时间差计算，不跟随世界时钟的“一天”长度；没有按房间规则批量开启的开关，只有每个玩家自己的开关。
- 计数表只增不删：调用过 `set_theft` 的玩家都会留下一条记录，随玩家数有界增长，当前没有清理。
- 收获命令的幂等载荷不绑定执行者：另一个玩家用同一 id 重放已提交的收获会得到 `duplicate=true` 的成功回执（不会重复改状态）。这是既有行为。
- `FarmStore.VERSION` 仍是 27，文档由 11 键变为 12 键；旧版本客户端会把新文档判为损坏——与本阶段“不承诺旧版本读回”的约定一致。
- 只测回环与两平台本地运行；真实局域网未验证。

## 关联

- 前置：[RECORD-04 玩家口袋与赠送](RECORD-04-gifts.md)、[RECORD-02 协作授权](RECORD-02-grants.md)。
- 设计：[社会与住宅](../../systems/society-housing.md)。
