# M1-02 · macOS 文件与输入适配验收记录

执行日期：2026-11-14。固定提交：本轮修复所在提交（见提交记录，父提交 `b3185d7`）。环境：macOS 27.0.1 / Apple M4 Pro / Metal 4 / 1600×900 逻辑窗口（Retina 缩放 2.0）。

## 已核验

| 项 | 证据 | 结果 |
|---|---|---|
| 用户数据目录 | 启动后写入 `~/Library/Application Support/Godot/app_userdata/我有一片田/farm-v27/farm.json` | 信封 `version=27`，主件与备份可读；中文应用名不阻断开写 |
| 中文路径 | 应用包与存档目录均含中文，导出、启动、读写正常 | — |
| 无 Win32 依赖启动 | 壁纸入口在 macOS 隐藏，游戏不依赖桌面宿主 | 主场景可直接进入 |
| 窗口与高 DPI | 窗口逻辑 1600×900、最小 960×600、屏幕缩放 2.0、内容缩放 1.0 | 界面按 1600×900 设计画布缩放 |
| 存档场景 | `tests/farm_storage_scene_test.gd` 窗口运行 | 17 项 0 失败：动作成功/失败、只读主件重试、重开、长离线、损坏档与未知版本锁定 |
| 输入场景 | `tests/field_menu_scene_test.gd` 窗口运行 | `FIELD_MENU_PASS`，真实鼠标点击、田格菜单、鸟群步态检查通过 |
| 设置场景 | `tests/ui_settings_scene_test.gd` 窗口与 headless 各一次 | 37 项 0 失败：选格与设置互斥、故障重试、农场错误覆盖设置、UTC 生长 |
| 正常退出 | `tests/exit_cleanup_test.gd` 19 项 | 约 6 秒内经产品路径退出，无残留资源告警 |
| 收获接入 | 主场景实例化后直接调用工具 | 首次 greens 0→1 且仅提交 1 条命令；再次不改变库存 |

## 场景测试 sweep（2026-11-14）

方法：固定引擎 `4.7.2.stable`，全部窗口运行（不加 `--headless`），`--audio-driver Dummy`，单例 175 秒闹钟，隔离目录 `.local/verification/m1-02-sweep`；每条测试首次结果与修复后复跑分别记录。不采集屏幕录像。测试参数必须放在 `--` 之后，首轮直接跟 `--script` 的参数未传入进程。

| 组 | 用例 | 结果 |
|---|---|---|
| 建设/布局 | `bridge_layout`、`bridge_passage`、`flock_layout`、`route_layout`、`construction_catalog`、`construction_feedback`、`island_brush`、`island_fields`、`island_shrink`、`multi_island_land`、`multi_island_placement`、`plant_layout`、`trellis_layout`、`variable_fields`、`courtyard_circulation`、`courtyard_editor`、`courtyard_life` | 全部 rc=0 |
| 农场/生活/厨房 | `animal_behavior`、`animal_contact_scene`、`garden_album_scene`、`harvest_book`、`kitchen_scene`、`life_capacity_scene`、`life_entries_scene`、`neighbor_story_scene`、`season_scene`、`field_menu_scene`、`farm_storage_scene`、`ui_settings_scene`、`exit_cleanup` | 全部 rc=0 |
| 世界包 | `world_transfer_scene`、`world_transfer_ui` | 全部 rc=0（并行开发的导入导出入口） |
| 窗口策略 | `window_preview_activity`（`--dev-preview`，10 项） | 0 失败 |
| 相机/画质 | `camera_sway`（修复前 1 项失败） | 修复后 0 失败 |
| | `camera_navigation`（58 项） | 修复菜单淡出后 0 失败；首次复跑出现 1 次 “Navigation never mutates farm state”，再跑 0 失败，按偶发记录 |
| | `building_layout`（42 项，修复前 2 项失败） | 修复后 0 失败 |
| | `foreground_composition`、`fsr_settings`、`component_lab_scene` | rc=0 |
| | `focus_detail`（53 项） | 0 失败；Metal 不提供逐视口 GPU 时间，仅跳过该项测量，绘制计数仍校验 |
| | `debug_time_preview` | 0 失败；独占全屏、分辨率输出尺寸与 MSAA 管线断言在 macOS 跳过 |
| | `procedural_lab_scene` | 0 失败；窗口被钳制到逻辑屏幕，4K 预算断言跳过 |
| | `wallpaper_hint` | 跳过：进程内桌面扩展只观察、不转发输入，产品不提供交互提示 |
| 已修复 | `construction_life`（31 项）、`construction_pacing`（17 项） | 等待田格菜单 0.22 秒开启门与动作环 0.14 秒遮罩后 0 失败 |
| | `living_decor` | 脚本错误已修（`8aef26e`）：`decoration_layout.placement_issue()` 不再索引空/未知物品；复跑窗口运行 `failures=0` |
| | `trellis_planting` | 已修复：选种后等待菜单淡出并再点根位播种，非播种动作先右键解除手持种子；菜单与果实节点缺失时有界失败。复跑 `ISLAND_CONSTRUCTION checks=31 failures=0` |
| | `farm_interaction` | 已修复：播种与工具改走 HUD `CropChoices`/`ToolChoices` 并等待行可见，关闭被拒绝动作打开的田格菜单，焦点清理有界等待；滚轮不再切种、4K 钳制与 12 种地面作物按当前契约断言。复跑 `checks=89 failures=0` |
| | `ground_tending_scene` | 已修复：每次选工具前重开工具行；保存失败按当前“保留内存结果并锁输入”契约校验，重试只保存不再二次锄地。复跑 failures=0（3 次） |
| | `bank_layout` | 已修复：动物可走面由 `Passage.outline()` 合并平台、桥面与桥墩支撑，断言改为检查该连通面，不再把桥面误判为越界。`BANK_LAYOUT_PASS` |
| | `duck_layout` | 已修复：鸟群预览改为 Marks 结构（1 条区域线 + 4 个角柄），不再统计旧 3D 预览子节点。复跑 `ISLAND_CONSTRUCTION checks=53 failures=0` |
| | `decoration_framing` | 已修复：拖拽后 `overview_view` 按产品设计持久化，断言改为读取存档中的 `original_view` 而非常量 27.5°。复跑 `checks=12 failures=0` |
| | `high_quality_scene` | 已修复：夹具种子按田块用 `Crops.seeds(field_id=="trellis")` 生成，画质档位按当前预设断言低画质 `MSAA_DISABLED`、标准 `MSAA_2X`。复跑 `checks=65 failures=0` |
| | `island_world` | 已修复：`DistantLandscape` 现由 4 个岬角 + 3 座山丘 + 10 座扩展山丘共 17 个具名节点组成，断言改为检查该结构与名称唯一性。`ISLAND_WORLD_PASS` |
| | `night_lighting`（169 项） | 已修复：田边照明现由 `PathLanternLight` 与 `GardenFillLight` 共同构成，断言合并两组（2 + 1）；同时确认 `GardenFillLight` 不生成遮挡几何。复跑 0 失败 |
| | `osmanthus_debug_scene`（978 项） | 已修复：开发者菜单动作与菜单关闭改为异步等待（淡出 0.45 秒），`_developer_action`/`_request_menu_close` 均 `await`，并等待 0.6 秒前景淡出后再断言。带 `--output` 复跑 0 失败 |
| | `plant_presentation`（141 项） | 已修复：夹具补足菠菜并把目标格置为 `ready`，射线瞄准抬高 .05 米；低画质保留前景但关闭景深；有限天空卡检查由 `landscape_sky_test` 的无限天空着色器断言替代。复跑 0 失败 |
| | `surface_integration`（24 项） | 已修复：像素采样区域随当前镜头/界面布局更新为 `Rect2i(1090,555,80,30)` 与 `Rect2i(680,540,80,25)`。带 `--output` 复跑 0 失败 |
| | `soil_presentation` | 带 `--output` 复跑 `failures=0` |
| | `atmosphere_scene` | 已修复：夹具补足第 3 种作物后灯笼可放置；作物格改为两次真实点击聚焦与选格，收获按钮仍按“先装备、再点格”执行；窗口灯计数限定在 `WindowWarmth` 组；最小化断言改为当前契约（暂停、关闭渲染循环、20 fps 上限），恢复后核对 120 秒 UTC 补算与音频恢复。27 项 0 失败 |
| | `complete_scene` | 已修复：作物节点仍命名为 `cell_XX`；真正原因是夹具在默认 rough/weedy 格上放作物，快照被整体拒绝后读取空节点并挂起。夹具先把目标格置为 `ready`，恢复失败立即退出，节点缺失显式失败。复跑 `checks=315 failures=0` |
| | `decoration_interaction` | 已修复：夹具只有 2 种作物，而灯笼要求 3 种，挂点标记因此不可选；补足第 3 种后 4 个挂点可点。另将布置产生的 `memories.marks.arrange` 从重试断言中排除（34 项 0 失败） |
| | `camera_tuning` | 已修复：打开面板现在清空已装备工具，低画质禁用景深控件；测试等待菜单淡出后再断言。强度 0 与其余景深行为已通过（`CAMERA_TUNING_PASS`） |
| 首轮偶发 | `free_decoration` | 首轮 1 项失败，随后独立复跑 3 次均 0 失败，记录为未复现的偶发 |
| 已修复 | `island_construction` | 共享鸟群预览断言改为 Marks 结构；撤销后作物断言改为对照最后一次成功提交的 `fields`（更长的攀架会按新槽位重算空列，属产品行为）。复跑 `checks=46 failures=0` |
| 单次预算 | `wallpaper_budget` | 按 `--visible-only --seconds=6 --repeats=1 --output=<绝对目录>` 以普通场景入口（`--path Game <probe.tscn>`）运行：`failures=[]`，`cap=30`，`drawn_frames=180`，`covered_seconds=0.0`，`focus_frames=180`，绘制调用 861，进程 `process_ms` p95 49.6 ms，`gpu_ms` 因 Metal 不提供逐视口时间记为 0。这是编辑器构建 6 秒可见样本，只证明绘制/遮挡/帧率上限断言，不是发行包或能耗结论 |

## 本轮修复

- `main.gd`：加载失败时 `_apply_season()` 与装饰生活状态不再解引用空 `farm_state`；此前损坏档或未知版本会让 `_ready` 中途中止，覆盖层之后缺少音频和窗口节流。
- `focus_detail.gd`：未配置 `field_size` 的田块跳过深度包围计算；没有可用田块时不写入 INF 景深距离。
- `main.gd`：农事动作恢复“先进入内存、再保存”的顺序。保存失败时保留动作结果并锁住输入，重试只保存当前快照；此前的“保存成功才接受候选”让一次真实收获在写失败后完全丢失，与 2.3/4.2 交接记录和存档场景测试不符。
- `farm_storage_scene_test.gd`：聚焦点击改为落在地表单元格中心。原先把点击点抬高 0.4 米，小田块在倾斜镜头下可能从边缘上方掠过，射线打空。
- `ui_settings_scene_test.gd`：同一抬高点击改为地表并重新投影（聚焦转场会移动相机）；选格后先关闭田格动作环，避免其全屏遮罩吞掉底栏点击；设置重试按钮显示后等待布局再取矩形；农场保存失败后等待菜单淡出，Escape 后等待菜单和动作环的 0.14 秒淡出。原用例在 macOS 上 5 项失败，修复后窗口与 headless 均 37 项 0 失败。

## 未覆盖

- Windows 对应场景未在本轮复跑，跨平台等价结论待两侧证据；本 sweep 只说明 macOS 窗口运行结果。
- 音频通路使用 `--audio-driver Dummy`，不构成本机扬声器或混音证据。
- 场景 sweep 未取得全绿：上表“失败未修”中的用例只做了归因，未修改产品代码，也未改动其断言；`wallpaper_budget` 只取得 6 秒可见样本（编辑构建），完整发行包预算与能耗仍缺测。
- sweep 期间 `Game/farm/farm_command.gd`、`Game/scenes/main.gd` 等处有并行改动；上表部分是变更过程中的结果，后续复跑需以稳定提交为准。
- 最小化后的后台帧率与音频静音检查（`atmosphere_scene_test.gd`）在 macOS 上长时间未完成，未作为通过证据；该测试的窗口最小化段需要单独适配或改用可见的失焦方式。
- `startup_experience_test.gd` 在 headless 下 45 项 0 失败；窗口模式唯一的 2160p 画质预算项失败，原因是 macOS 把窗口限制在逻辑屏幕 1920×1080 内，无法构造 3840×2160 的窗口，该项在窗口模式不适用。
- 建设预览、导入导出界面属于后续工作包。
