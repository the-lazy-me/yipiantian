# M0-05 · 双平台规则夹具执行记录

执行日期：2026-11-15。触发提交：`a08457f`（`main`）。工作流：[`rule-tests.yml`](../../../../.github/workflows/rule-tests.yml)。CI 运行：<https://github.com/the-lazy-me/yipiantian/actions/runs/43617023131>（macOS 与 Windows 均 success）。本次在既有 7 个规则套件之外加入 `world_transfer_test`、`headless_world_runtime_test`、`headless_event_schedule_test`，使世界包导出/导入与无头世界也在两平台执行；此前 `2c6c299` 的 774 项基线见提交历史。

## 环境

- 两级均使用 GitHub 托管 runner（`macos-latest`、`windows-latest`）与固定 Godot `4.7.2-stable`；下载 zip 在任务内校验 SHA-256。
- 干净检出，只取 Git 内容、不取 LFS 资源；规则夹具只预加载 GDScript，不加载主场景、3D 资源或 GPU。
- 测试数据写入 runner 临时目录下的 `.local/verification/`，不接触真实存档。

## 结果

| 套件 | macOS | Windows |
|---|---:|---:|
| `farm_state_test.gd` | 385 / 0 失败 | 385 / 0 失败 |
| `farm_store_test.gd` | 109 / 0 失败 | 109 / 0 失败 |
| `settings_store_test.gd` | 53 / 0 失败 | 53 / 0 失败 |
| `farm_command_test.gd` | 26 / 0 失败 | 26 / 0 失败 |
| `world_package_test.gd` | 106 / 0 失败 | 106 / 0 失败 |
| `v27_importer_test.gd` | 68 / 0 失败 | 68 / 0 失败 |
| `farm_v27_fixtures_test.gd` | 27 / 0 失败 | 27 / 0 失败 |
| `world_transfer_test.gd` | 72 / 0 失败 | 72 / 0 失败 |
| `headless_world_runtime_test.gd` | 53 / 0 失败 | 53 / 0 失败 |
| `headless_event_schedule_test.gd` | 56 / 0 失败 | 56 / 0 失败 |
| 合计 | 955 / 0 失败 | 955 / 0 失败 |

两平台每套件的检查数、失败数与汇总行一致，退出码均为 0。导入器写出的世界包与报告在 Windows 上也逐字节通过同一幂等与拒绝断言。`world_transfer_test` 在同一平台上完成“导出包→隔离应用→逐字段一致”的往返；它不在机器之间传递同一个包，因此不等于跨设备交接证据。

## 边界

- 未注入人为失败来比较两平台的错误文本；本记录只证明合法与既有拒绝夹具的语义一致。
- 没有运行窗口、UI、桌面壁纸或 GPU 场景；Windows 桌面宿主与 macOS 嵌入分别由各自记录覆盖。
- 场景类套件（`social_panel_scene_test`、`room_panel_scene_test`、`startup_room_test`、`m4_client_scene_test`）在干净检出里无法编译：它们预加载的美术在 LFS 中是 1.6 GB 指针文件。工作流按 `Game/art/ui/game-icon.png` 是否为 LFS 指针判定，缺美术时逐个打印 `skipped=no-art` 并计入汇总行，不伪装成通过。这些套件只在有美术的本地检出执行。
- 工作流为手动触发，不随每次提交自动运行；运行成本与 runner 标签变更需维护。
- `macos-14` 标签在此仓库报 runner 配置不受支持，两个工作流均改用 `macos-latest`；`build-macos.yml` 的云端原生构建与导出尚未运行验证。

## 结论

M0-05 的“两个平台输出语义相同”已有干净检出的自动化证据；失败样本复现差异与完整安装包跨平台验收仍未覆盖。
