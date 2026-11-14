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
| | `trellis_planting` | 已加入菜单开启门等待；其余失败为下述过期断言（4 项） |
| | `farm_interaction` | 预期过期：HUD“种植”现在打开 CropChoices，不再生成 `field_menu.cards`；61 项中 28 项失败、6 处空引用 |
| | `ground_tending_scene` | 预期过期：选择工具会关闭工具面板，用例再次点击“锄头”时按钮已禁用；2 项失败 |
| | `duck_layout` | 预期过期：共享断言仍按 `_preview.get_child_count()==5` 检查鸟群预览，当前为 Marks 结构；2 项失败 |
| | `bank_layout` | 纯 2D 几何断言 `Walking cannot leave the plateau` 失败，与平台无关；需产品侧确认是布局变更还是回归 |
| | `decoration_framing` | 修复菜单淡出后剩 2 项：拖拽后 `overview_view` 按产品设计持久化为 24.26°，用例仍期望常量 27.5°；属过期预期 |
| | `high_quality_scene` | `restore_snapshot` 拒绝混合阶段夹具（4 项失败），夹具与当前校验不一致 |
| | `island_world` | `DistantLandscape` 现由 4 个岬角 + 3 座山丘 + 10 座扩展山丘组成，断言仍要求 5 个子节点 |
| | `night_lighting`（163 项） | 断言 3 盏 `PathLanternLight`，当前前沿灯为 `GardenFillLight`（2 + 1）；与 `camera_sway` 的灯柱检查一致，属过期计数 |
| | `atmosphere_scene` | 夹具只有 2 种作物，灯笼未解锁导致 `lights[0]` 越界；随后仍在窗口最小化段挂起，未作为通过证据 |
| | `complete_scene` | 作物节点不再按 `cell_01` 命名，读取 `scene_file_path` 空引用后协程中止并超时；需单独适配 |
| | `decoration_interaction` | 地面槽位输入正常，4 个挂点槽位点击后 `preview` 为空（34 项中 11 项失败），未归因 |
| | `camera_tuning` | 3 项失败：打开面板未清空已装备工具、强度 0 未关闭远景景深、低画质未禁用景深控件；未归因 |
| 首轮偶发 | `free_decoration` | 首轮 1 项失败，随后独立复跑 3 次均 0 失败，记录为未复现的偶发 |
| 未有效运行 | `osmanthus_debug_scene`、`plant_presentation`、`soil_presentation`、`surface_integration`、`wallpaper_budget` | 首轮参数未传入；`osmanthus` 在无参数路径断言后不退出而超时，其余立即退出。需按 `--` 语法重跑后才可给结论 |

## 本轮修复

- `main.gd`：加载失败时 `_apply_season()` 与装饰生活状态不再解引用空 `farm_state`；此前损坏档或未知版本会让 `_ready` 中途中止，覆盖层之后缺少音频和窗口节流。
- `focus_detail.gd`：未配置 `field_size` 的田块跳过深度包围计算；没有可用田块时不写入 INF 景深距离。
- `main.gd`：农事动作恢复“先进入内存、再保存”的顺序。保存失败时保留动作结果并锁住输入，重试只保存当前快照；此前的“保存成功才接受候选”让一次真实收获在写失败后完全丢失，与 2.3/4.2 交接记录和存档场景测试不符。
- `farm_storage_scene_test.gd`：聚焦点击改为落在地表单元格中心。原先把点击点抬高 0.4 米，小田块在倾斜镜头下可能从边缘上方掠过，射线打空。
- `ui_settings_scene_test.gd`：同一抬高点击改为地表并重新投影（聚焦转场会移动相机）；选格后先关闭田格动作环，避免其全屏遮罩吞掉底栏点击；设置重试按钮显示后等待布局再取矩形；农场保存失败后等待菜单淡出，Escape 后等待菜单和动作环的 0.14 秒淡出。原用例在 macOS 上 5 项失败，修复后窗口与 headless 均 37 项 0 失败。

## 未覆盖

- Windows 对应场景未在本轮复跑，跨平台等价结论待两侧证据；本 sweep 只说明 macOS 窗口运行结果。
- 音频通路使用 `--audio-driver Dummy`，不构成本机扬声器或混音证据。
- 场景 sweep 未取得全绿：上表“失败未修”中的用例只做了归因，未修改产品代码，也未改动其断言；`osmanthus_debug_scene`、`plant_presentation`、`soil_presentation`、`surface_integration`、`wallpaper_budget` 因参数未传入而未形成有效结果，`wallpaper_budget` 的 6 秒预算项仍未测量。
- sweep 期间 `Game/farm/farm_command.gd`、`Game/scenes/main.gd` 等处有并行改动；上表部分是变更过程中的结果，后续复跑需以稳定提交为准。
- 最小化后的后台帧率与音频静音检查（`atmosphere_scene_test.gd`）在 macOS 上长时间未完成，未作为通过证据；该测试的窗口最小化段需要单独适配或改用可见的失焦方式。
- `startup_experience_test.gd` 在 headless 下 45 项 0 失败；窗口模式唯一的 2160p 画质预算项失败，原因是 macOS 把窗口限制在逻辑屏幕 1920×1080 内，无法构造 3840×2160 的窗口，该项在窗口模式不适用。
- 建设预览、导入导出界面属于后续工作包。
