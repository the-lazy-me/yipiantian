# M6-02 · 区域降雨与地块湿度

状态：切片完成（2026-11-15），未验收。范围：降雨补水、非雨失水、浇水改变局部湿度、可解释的有限生长影响；温度、肥力、排水、灾害不在本切片。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/farm_state.gd` | 新增可注入环境源（`set_environment`）；格子增加持久字段 `moisture`；`_settle_data` 在有环境时按天气块逐段结算，无环境时保持原加法规则；`water` 把该格湿度置满；`get_cell` 暴露 `moisture`、`moisture_label`、`growth_rate`；`valid_cell_snapshot` 要求原有五键、允许 `planted_by`／`moisture` 各自缺省且拒绝未知键，`restore_snapshot` 补默认值；`copy()` 传递只读天气源。 |
| `Game/world/headless_world.gd` | 打开时把 `NatureState` 注入 `FarmState`；`advance_to()` 把 `next_weather_at()` 的块边界加入推进分段点；`summary()` 的格子视图携带湿度与倍率。 |
| `Game/world/world_member.gd` | 从权威摘要恢复时同样注入自然状态，成员本地的派生视图与权威一致。 |
| `Game/farm/world_command_entry.gd` | 无场景单命令入口读取 `nature.json` 并注入，缺文档沿用固定默认种子。 |
| `Game/scenes/main.gd` | 单机加载按 `HeadlessWorld.open()` 同一语义读取 `nature.json`：缺失用固定默认种子，损坏或较新版本具名失败并走既有覆盖层；新建与恢复两条路径都注入 `NatureState`。所有本地农场提交统一先落种子，种子写失败沿用既有保存失败处理。 |
| `Game/scenes/farm_hud.gd` | 选中田格时在 HUD 增加一行只读「土壤：干燥／湿润／潮湿 · 生长 50%／100%」，数据来自 `get_cell()` 的 `moisture_label` 与 `growth_rate`；无面板、图标或动画。 |
| `tests/rain_moisture_test.gd` | 新增 94 项检查，见下。 |
| `tests/single_player_nature_scene_test.gd` | 新增 35 项场景检查：缺失文档写默认种子、损坏／较新文档拒绝且不覆盖、种子写失败阻断保存、晴天变干后 0.5 与 HUD 文案、浇水后 1.0、复制候选走同一条先落种子的写盘路径。 |
| `tests/headless_world_runtime_test.gd` | 直连对比夹具改为注入同一自然状态（天气现在是结算输入）。 |
| `tests/headless_event_schedule_test.gd` | 夹具固定种子；下一事件期望按当前块倍率换算；分段上限加入天气边界数。 |

世界包格式未改（湿度随农场快照自然携带），`V27Importer.KNOWN_FARM_KEYS` 未改（不含格子内部键），v27 夹具继续通过。

## 规则与确定性

- **环境依赖方向**：`FarmState` 只调用注入对象的 `weather_at(utc_seconds)`，不读全局、存储或系统时钟；`NatureState` 仍是天气唯一所有者。会话负责把天气块边界作为推进分段点，因此在线小步、离线一次推进和单命令入口结果一致。
- **块内常量倍率**：`rain` 为 1.0；`clear`/`cloudy` 时土壤湿度 ≥ 0.5 为 1.0，< 0.5 为 0.5；未知天气 1.0。倍率只取 1 或 1/2，湿度只以 1/16 的整数倍在块边界变化，因此一次推进与按天气边界／生长边界／整秒分段推进的结果逐项相同，测试直接比较整份快照。
- **湿度**：新格 0.5；每完成一个 6 小时块，`rain` +0.25（上限 1）、`cloudy` −1/16、`clear` −1/8（下限 0）；块内结算不改湿度。浇水把 `water` 命令作用的那一格置为 1，相邻格不变。没有新增“干燥累计”等派生持久字段。
- **玩家可见解释**：`get_cell()`／`summary()` 给出 `moisture`、`moisture_label`（dry/damp/wet）和 `growth_rate`。干燥只让作物变慢，成熟后封顶；产量、收获上限、偷菜与住宅语义不变，长期离线不会枯死。

## 实际验证

命令均在仓库根目录执行，引擎为 `/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot`。

```
RAIN_MOISTURE_TEST checks=94 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/rain-moisture-200821
FARM_STATE_TEST checks=385 failures=0
FARM_STORE_TEST checks=109 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/farm-store-208572
HEADLESS_WORLD_RUNTIME_TEST checks=60 failures=0
HEADLESS_EVENT_SCHEDULE_TEST checks=56 failures=0
NATURE_STATE_TEST checks=136 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/nature-state-209042
V27_IMPORTER_TEST checks=69 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/v27-import-213404
V27_FIXTURES_TEST checks=27 failures=0 root=/Volumes/Disk-1tb/yipiantian/tests/fixtures/v27
WORLD_PACKAGE_TEST checks=123 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-package-211274
WORLD_TRANSFER_TEST checks=113 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-transfer-235511
WORLD_SNAPSHOT_TEST checks=31 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/world-snapshot-215057
M4_SYNC_TEST checks=39 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-sync-229920
```

单机场景接入补测（2026-11-15）：

```
SINGLE_PLAYER_NATURE_TEST checks=35 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/single-player-nature-236024
FARM_STORAGE_SCENE_TEST checks=17 failures=0 directory=/Volumes/Disk-1tb/yipiantian/.local/verification/storage-scene-204738
```

复核（2026-11-15，切片作者以外，提交前）：`NATURE_STATE_TEST 136`、`RAIN_MOISTURE_TEST 94`、`FARM_STATE_TEST 385`、`HEADLESS_WORLD_RUNTIME_TEST 60`、`V27_IMPORTER_TEST 69`、`WORLD_SNAPSHOT_TEST 31`、`SINGLE_PLAYER_NATURE_TEST 35`、`FARM_STORAGE_SCENE_TEST 17`、`FARM_INTERACTION_TEST 80`、`WORLD_TRANSFER_SCENE_TEST 14`、`M4_CLIENT_SCENE_TEST 29`，均 `failures=0`。复核时 `_save_state` 的共享世界分支由“返回成功”改为 `push_error` 加 `shared_world` 失败：所有本地写入入口本已在打开前拒绝联机模式，这个分支只在将来漏门禁时暴露问题，不能伪装成已提交。

`single_player_nature_scene_test` 加载真实 `main.tscn`，需要已拉取的美术资源；CI 的干净检出没有 LFS 美术时会跳过同类场景夹具（本测试尚未登记进规则工作流）。

`WORLD_TRANSFER_TEST` 的一行 `Could not create directory ... .pending-world-...` 是“导入写入失败”夹具预期的失败路径输出，断言仍全通过。`M4_SYNC_TEST` 使用 600 秒超时，其余 300 秒。补充回归：`FARM_COMMAND_TEST 45`、`PLAYER_THEFT_TEST 128`、`PLAYER_BAGS_TEST 114`、`TRELLIS_PLANTING_STATE 23`、`M4_JOIN_TEST 54`、`WORLD_LAB_TEST 47`（含无场景运行器两次同种子对照），均 `failures=0`；无场景单命令入口手工冒烟一次为 `stage=committed`、`greens=1`。`HEADLESS_WORLD_RUNTIME_TEST` 另重复运行 20 次均为 `60 failures=0`。

新测试覆盖：降雨块与晴朗块生长差异（含土壤先变干再测）；浇水只改变本格湿度并立即恢复倍率；700 秒分段推进与一次推进快照逐项相同；跨多个天气块（雨／晴／多云交替）；30 天晴朗离线一次推进与按块推进一致且到干燥下限；临界成熟时浇水封顶为满进度并只产出一篮；会话按天气边界分段；非法时间、非法湿度、未知天气种类、不可用天气源与块边界幂等；v27 五键与六键格子仍可恢复并补默认值。

## 单机场景接入

2026-11-15 补。单机不再按旧加法规则结算：

- **加载**：`main.gd` 以 `store.directory` 建立 `NatureStore`，读取语义与 `HeadlessWorld.open()` 相同。`nature.json` 缺失时采用固定默认种子而不是重抽；存在但损坏或版本较新时打印 `NATURE_LOAD stage=failed kind=...`，复用既有加载失败覆盖层，原文件不改写，也不创建新农场。覆盖层的重试会重新读取自然文档。
- **注入**：新建 `FarmState` 直接接收 `NatureState`，恢复路径调用 `set_environment()`；单机格子因此与权威世界一样按 6 小时天气块结算。既有存档首次载入时会先补结算到当前时间，再写盘。
- **写盘**：`_save_farm` 与动物、菜篮、厨房、季节、建设、整理等直接提交统一经 `_save_state`／`_save_state_snapshot`。种子先于农场文档落盘；写入前重读，若另一实例已提交种子则采用它，损坏时拒绝覆盖。种子写失败返回 `save_nature_*`，由既有 `_save_failed`、输入锁和 `show_storage_issue(..., true)` 呈现，不新增错误界面。
- **展示**：选中田格时，HUD 在既有布局里显示一行「土壤：湿润 · 生长 100%」；未选中时不显示。只读消费 `get_cell()` 已有派生值，不增加常驻面板、图标系统、动画，也不改镜头和布局。

## 未覆盖

- 单机已接入自然状态并在选中田格时显示土壤湿度与生长倍率（见上节）。温度、肥力、排水、暴雨／干旱灾害、真实天气适配器与跨季节数值均未实现。
- 天气块边界未加入 `next_event_utc()` 的返回值，只在实际推进时作为分段点；服务端空闲节拍不会因天气单独唤醒，但任何 `advance_to()` 目标的结果仍与分段无关。
- 未新增美术或依赖；HUD 仅增加一行只读文本。`rain_moisture_test` 已登记进规则工作流。

CI 证据：规则工作流 run `43655467206`（提交 `7b52d02`）macOS 与 Windows 全部通过。单机接入切片补证：run `43671607687`（提交 `d92fa81`）两平台全部通过，`nature_state_test 136`、`rain_moisture_test 94` 均为 `failures=0`，42 项规则夹具仅 5 项无美术场景夹具按既有策略跳过；`single_player_nature_scene_test` 需要 LFS 美术，本地窗口运行 35 项通过，未登记进工作流。

## 相关裁决

- [ADR-008 区域降雨与地块湿度](../../decisions/ADR-008-rain-moisture.md)
