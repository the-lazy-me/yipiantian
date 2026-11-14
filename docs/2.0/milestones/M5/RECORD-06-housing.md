# M5-04 · 住宅首版：占地与工期（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M5 或 M5-04 验收完成。裁决：[ADR-006](../../decisions/ADR-006-housing-slice.md)。前置：[M5-01 社交](RECORD-01-social.md)、[M5-03 偷菜](RECORD-05-theft.md)。

## 问题

M5-04 要求“蓝图预览、用地检查、材料检查、确认施工、完成与使用”，验收含“相同占地并发建造只成功一次、材料无复制、房屋迁移后重建”。但世界还没有任何建材来源：经济只有作物口袋与公共库存，交易与市场在 M7。此时凭空发明木料／石料产出，会与 M7 的定价和存量规则正面冲突。

## 决定与边界

[ADR-006](../../decisions/ADR-006-housing-slice.md)：首版只做**占地、工期、拆除**；不引入材料账本。宅基用固定命名槽位（`yard_a`…`yard_f`），不是任意坐标。

## 实现

### 目录

- `Game/farm/building_catalog.gd`：六个宅基槽位（中文名）、三个蓝图（小屋 10 分钟、工坊 20 分钟、凉亭 5 分钟）。槽位与工期是数据，改数量不改规则。

### 状态

- 农场文档新增 `buildings: {slot_id: {blueprint, owner, started_utc, done_utc}}`，与 `fields`、`bags`、`theft` 同一次落盘；文档键数由 12 变为 13（`buildings` 与 `bags`、`theft` 一样缺省可选、存在则严格校验）。
- `build(slot_id, blueprint, now, actor)`：只有具名成员能建，建造者即房主；槽位已有建筑（施工中或已完工）→ `occupied`；未知槽位/蓝图分别具名拒绝；`done_utc = now + 工期`，若溢出为无穷则按 `invalid_time` 拒绝。
- `demolish(slot_id, now, actor)`：施工中与已完工都可拆；只有房主能拆（`not_owner`），空槽位 `empty`。
- 施工中/已建成的判定直接比较 `now_utc` 与 `done_utc`，不加定时器、不改时间结算。

### 命令与权威

- 命令 `build`（`{id, kind, slot_id, blueprint, at_utc}`）与 `demolish`（`{id, kind, slot_id, at_utc}`）走与收获、赠送相同的权威命令通道与同一本幂等账本：同一槽位的两次建造只有先到的一笔提交，后到的一笔看到 `occupied`，因此“相同占地并发建造只成功一次”由账本与状态共同保证。
- 幂等载荷绑定权威解析出的执行者：同一 id 换一个玩家重放会得到 `command_conflict`，不能借别人的 id 拆房。
- 匿名成员在权威入口即被 `no_player` 拒绝；建造不在协作授权范围内（授权管田地工作，不管住宅）。

### 客户端

- 农场控制条新增“宅基”入口（仅共享世界显示），打开宅基面板：逐槽位显示空置、施工中（剩余分钟按世界时钟算）、已建成；空位可选蓝图后建造，自己的房子可取消或拆除，别人的只显示状态。
- 面板只发意图，不判断权限；权威回执或邻居广播后刷新。
- 邻居建造/拆除会在提示行里出现（“小满 盖起了小屋”“小满 拆掉了一座房子”）。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 150 "$GODOT" --headless --path Game \
  --script "$PWD/tests/building_test.gd"
perl -e 'alarm shift; exec @ARGV' 90 "$GODOT" --headless --path Game \
  --script "$PWD/tests/build_panel_test.gd"
perl -e 'alarm shift; exec @ARGV' 240 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_client_scene_test.gd"
```

结果：`BUILDING_TEST checks=149 failures=0`（连续两次）；`BUILD_PANEL_TEST checks=17 failures=0`。回归 `FARM_STATE_TEST 385`、`FARM_COMMAND_TEST 45`、`PLAYER_BAGS_TEST 114`、`PLAYER_THEFT_TEST 128`、`M4_CLIENT_SCENE_TEST 27` 均为 `failures=0`。

CI 证据（规则工作流 run `43649341144`，提交 `cd150a9`）：macOS 与 Windows 都通过；`building_test` 两平台 `checks=149 failures=0`，`player_theft_test` 两平台 `checks=128 failures=0`，`m4_reconnect_test` 两平台 `checks=27 failures=0`。`build_panel_test` 属场景用例，无美术的 CI 检出按 M0 RECORD-06 的跳过策略记为 `skipped=no-art`，面板验证以本机结果为准。

| 用例 | 实际观察 | 结果 |
|---|---|---|
| 目录 | 槽位唯一、蓝图字段完整、工期与定义一致、未知 ID 返回空 | 通过 |
| 建造 | 具名成员成功；状态 `building`；到 `done_utc` 变为 `done` | 通过 |
| 权限 | 匿名/非法玩家 `invalid_player`；未知槽位 `invalid_slot`；未知蓝图 `invalid_blueprint` | 通过 |
| 占用 | 同一槽位第二次建造（施工中、已完工各一次）`occupied`，原记录不变 | 通过 |
| 并发 | 两个不同命令 id 依次提交同一槽位，只有第一个成功 | 通过 |
| 拆除 | 房主可拆（施工中、完工后）；他人 `not_owner`；空槽 `empty`；拆后回到 `empty` | 通过 |
| 幂等 | 同 id 重放 `duplicate=true`；同 id 换载荷或换执行者 `command_conflict`；带 `from` 判非法 | 通过 |
| 落盘 | `FarmStore` 往返后建筑与时间不丢；缺 `buildings` 的旧文档可恢复；非法表整份拒绝 | 通过 |
| 面板 | 空位可选蓝图并建造；施工中显示剩余分钟与取消；别人的房子没有操作；房主看到拆除 | 通过 |

## 新增农场文档键的落地清单

农场文档每多一个键，要同时改三处：`FarmState._valid_snapshot` 的键数与逐表校验、`valid_cell_snapshot`（若改的是格子形状）、`V27Importer.KNOWN_FARM_KEYS`。本次漏了第三处：导入器把世界自己的 `buildings` 当成未知字段，`v27_importer_test` 两平台各失败 2 项。已在 `Game/farm/v27_importer.gd:28` 补上。

## 未覆盖

- **没有材料**：建造不扣资源、拆除不回收，ADR-006 记录的边界。M5-04 验收里的“材料无复制”在本版没有对象，随 M7 交易实现。
- **没有三维呈现**：住宅只存在于状态与面板里，场景中不显示房子；`Game/scenes/procedural_lab/house_kit.gd` 尚未接入。
- **没有坐标与几何**：固定槽位代替任意摆放，没有重叠、接地、入口与通行检查；这些属于院落编辑器切片。
- 拆除不要求时间晚于开工，可以倒填时间；`buildings_at` 按插入顺序返回，不保证与槽位目录同序。
- 房屋不能移动或迁移重建；“迁移后重建”仍只是拆除后重新建造。
- 建造只测回环与本机两平台；真实局域网与两平台同时建造未验证。

## 关联

- 裁决：[ADR-006](../../decisions/ADR-006-housing-slice.md)。
- 前序：[RECORD-05 偷菜](RECORD-05-theft.md)、[RECORD-01 社交](RECORD-01-social.md)。
