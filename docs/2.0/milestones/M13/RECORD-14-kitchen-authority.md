# M13-14 · 厨房动作接入世界权威命令

日期：2026-11-16。状态：**本机无头切片完成，未验收**。范围：把厨房的 `start/collect/display/share` 四种动作接入世界权威命令通道，关闭 [RECORD-13](RECORD-13-peaceful-life.md) 记录的功能缺口「厨房动作没有权威命令入口，因此规则可达而联机成员不可达」。切片只做命令边界、权限、联机客户端转发与规则测试，不改厨房规则本身，不做真实 WSS 端到端、界面点按或 Windows 验证。

前置：[M13 PLAN](PLAN.md)、[RECORD-13 · 无联网完整生活](RECORD-13-peaceful-life.md)、[M4 客户端](../M4/RECORD-06-client.md)、[M5 社交](../M5/RECORD-01-social.md)。

## 结论

1. **厨房动作已有一条权威路径。** `FarmCommand` 新增 `KITCHEN` 种类，命令形状固定为 `{id, kind, action, request, revision, at_utc}`；`WorldHost.execute_for_member` 按 `WorldInvite.allows` 判权限，`HeadlessWorld.execute` 沿用既有时间窗校验、`commands.execute` 幂等与 `store.save_state` 原子保存。成员经此路径可完成 start→collect，库存扣减与成品计数都落在共享 `farm.json` 的 `kitchen` 文档里。
2. **`start` 扣的是操作者自己的口袋。** 命令载荷不携带身份，`_apply` 用连接解析出的 `actor` 把候选的 `pantry_owner` 指向该玩家；拒绝路径丢弃候选，因此不会创建空袋或写入视图上下文。这与既有 `kitchen_action` 包装使用 `pantry_view()` 的语义一致。
3. **摆放状态不进命令载荷。** `execute()`/`_apply()` 增加可选 `decorations: Dictionary = {}`，只在 kitchen 分支使用；权威传 `decorations.snapshot()`，客户端单机路径传自己的快照。客户端无法自称小晒架已摆放，`garden_rack` 工位是否可用由权威文档决定。
4. **权限：成员允许，访客拒绝。** `WorldInvite.PERMISSIONS[MEMBER]` 增加 `"kitchen"`，`VISITOR` 不加。厨房改的是世界共享的厨房文档，不涉及玩家专属资产，因此没有额外的具名玩家门；匿名成员与非成员仍被 `WorldInvite.allows` 拦下。
5. **联机客户端发命令而不是本地改写。** `main.gd::_kitchen_action` 在 `remote != null` 时提交 `FarmCommand.make_kitchen(...)` 并登记 `_remote_pending`（工具名 `"kitchen"`）；`_apply_remote_command` 重放 kitchen 后走与本地相同的 `_adopt_kitchen`，刷新 `kitchen_display`、生命期装饰、`harvest_book` 与 HUD，share 动作切到 journal 页。权威对 kitchen 提交也会触发 `shared_changed` 摘要，其他成员的下一个摘要即可看到共享厨房文档；摘要应用时会刷新厨房显示与打开中的书页。
6. **访客界面语义。** 联机 HUD 原本隐藏“菜篮”，因此访客不会直接看到厨房入口；灶台等场景入口与厨房页在联机下不再被“联机模式下，厨房由世界房主使用。”拦下，访客点击后由权威以 `forbidden` 拒绝并显示“当前身份不能执行这个操作。”。厨房页在共享世界仍会显示相册/见闻标签；这两个标签依赖本机照片目录，联机下由 `memory_page` 显示一行“相册与见闻照片只保存在本机存档，联机世界暂不提供。”而不是空引用。
7. **单机也走同一命令边界。** `_kitchen_action` 的单机分支改为 `farm_commands.execute(farm_state, command, actor, decorations)`，使本地与权威共用一种命令形状与同一幂等账本；原先是直接调用 `candidate.kitchen_action(...)`。

## 实现

| 文件 | 变化 |
|---|---|
| `Game/farm/farm_command.gd` | 新增 `KITCHEN` 常量、`KITCHEN_ACTIONS`、`KITCHEN_REQUEST_KEYS`、`KINDS` 登记、`make_kitchen()`、`valid()` 精确键集与操作数校验、`_apply()` 分派、`_payload()` 绑定 actor（排序后的 request 键，避免字典顺序造成假冲突）；`execute()`/`_apply()` 增加可选 `decorations` |
| `Game/world/headless_world.gd` | `commands.execute(..., decorations.snapshot())`；kitchen 提交也发出 `shared_changed`，使其他成员收到摘要 |
| `Game/world/world_invite.gd` | 成员权限增加 `"kitchen"` |
| `Game/scenes/main.gd` | 联机厨房发命令；单机厨房改走命令边界；提取 `_adopt_kitchen`/`_refresh_kitchen_views` 供本地与重放共用；`_on_remote_committed` 的拒绝路径与 `_clear_remote_pending` 处理 `"kitchen"`；`_on_remote_changed` 对 kitchen 只等摘要、不按发送者口袋重放；`_on_remote_state` 刷新共享厨房；`_open_basket` 不再在联机下整体拒绝；`_exchange`/`_change_season` 补回联机拒绝提示；补厨房拒绝原因文案 |
| `Game/world/world_host.gd` | `_reason_text` 增加厨房规则的原因（`stale_kitchen`、`station_unavailable`、`wrong_crop` 等） |
| `Game/ui/memory_page.gd` | 无本机照片目录时给出明确文案，避免联机厨房页里相册/见闻标签空引用 |
| `tests/kitchen_authority_test.gd` | 新增规则+权威夹具 |
| `.github/workflows/rule-tests.yml` | 纯规则测试组登记 `kitchen_authority_test` |
| `docs/2.0/milestones/M13/PLAN.md`、`RECORD-13-peaceful-life.md` | 缺口句子改为已接入并链接本记录 |
| `docs/2.0/release/player-guide.md` 第 8 节 | 成员权限增加做饭与分享，并说明访客被权威拒绝 |

## 验证

命令：

```sh
G=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$G" --headless --path Game \
  --script "$PWD/tests/kitchen_authority_test.gd"
```

末行：

```text
KITCHEN_AUTHORITY_TEST checks=64 failures=0
```

覆盖：成员 start→collect 成功且口袋 6→5→…、成品 `stock.leaf_stir=1` 与 `records.made=1`；share 清空库存与展示并解锁 `drying_rack`；同 id 重放不二次扣菜、不二次加成品；旧 revision 返回 `stale_kitchen`；访客返回 `forbidden` 且 revision 不变；`garden_rack` 未摆放返回 `station_unavailable`、摆放后成功；非法 action、未知 request 键、负/小数 revision、`actor`/`from`/`from_id`/`owner_id`/`decorations` 字段均返回 `invalid_command`；重开同一目录后成品、分享计数、revision 与 `FarmCommand.has_committed` 均保留。

退出码 0。相关回归：`FARM_COMMAND_TEST checks=136 failures=0`、`WORLD_TAIL_TEST checks=31 failures=0`、`ISLAND_CONSTRUCTION checks=31 failures=0`、`WORLD_INVITE_TEST checks=33 failures=0`、`PANTRY_TEST checks=71 failures=0`（既有共享命令、邀请权限与口袋视图路径未被新参数破坏）。`main.gd`、`memory_page.gd`、`farm_command.gd`、`headless_world.gd`、`world_invite.gd`、`world_host.gd`、`kitchen_authority_test.gd` 全部通过 `--headless --check-only`。

`tests/kitchen_scene_test.gd` 在本机无头环境仍未跑完：400s、560s、600s 三次预算都以超时结束（最近一次 `alarm` 退出码 143），无 `KITCHEN_SCENE` 末行。日志停在主场景 `FARM_SAVE` 之后，证据目录里没有任何 PNG，说明它卡在第一张 `shot()` 等待的 `RenderingServer.frame_post_draw`；这与 [M7 RECORD-07](../M7/RECORD-07-pantry-ownership.md) 记录的同一表现一致，不是本切片引入。

## 未覆盖

1. **真实 WSS 端到端。** 夹具用 `WorldHost.execute_for_member` 直接驱动权威，没有真实会话、RPC、预条件序号或重连；摘要广播在夹具里被断开（模拟无传输对端的既有写法）。
2. **界面点按。** 厨房页在联机下的可见结果、访客提示文案与 share 切页只做了代码路径检查，未点按；`kitchen_scene_test` 在本机无头环境卡在 `frame_post_draw`，未取得末行。交付前已重启 macOS 开发预览（静音、全屏、`DEV_PREVIEW_READY screen=0 mode=4 size=(3840, 2160)`），确认新代码能加载进入农场，但未在窗口中实际点按厨房。
3. **相册/见闻的联机语义。** 目前只显示“仅本机存档”，没有把照片同步到权威；这是范围外，但也意味着联机厨房页的这两个标签仍是只读说明。
4. **访客的厨房入口。** HUD 隐藏“菜篮”，访客仍可通过场景灶台等入口打开厨房页并被权威拒绝；没有额外的界面预判或只读标记。
5. **Windows 与真实跨机。** 只在 macOS 无头运行。
6. **删除/布置装饰的权威路径。** 摆放状态仍由装饰文档承载；本切片只让厨房读取它，没有把装饰摆放本身接入命令通道。

## 发现

- 联机 HUD 原本隐藏“菜篮”，因此 `main.gd::_open_basket` 里只给联机用户看的“厨房由世界房主使用”提示实际很难触发；本次移除该门并让场景入口直接进入厨房页。
- `Game/ui/memory_page.gd` 在无 `files` 时（联机从未创建 `GardenAlbum`）会空引用；本次加了明确文案。这是本切片暴露的既有缺陷，属于最小必要修复。
- 未发现厨房规则本身的缺陷；`Kitchen.act` 的 revision、库存与分享计数语义与 `RECORD-13` 的离线夹具一致。
