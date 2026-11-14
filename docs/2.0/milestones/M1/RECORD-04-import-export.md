# M1-03 · 导入导出界面验收记录

执行日期：2026-11-15。工作树基于 `97f1245`，本轮改动尚未提交。环境：macOS 27.0.1 / Apple M4 Pro / arm64 / Godot 4.7.2-stable（Metal 4；以下测试均为 headless）。

## 已核验

| 项 | 证据 | 结果 |
|---|---|---|
| 世界包导出 | `tests/world_transfer_test.gd` | 从运行中的 v27 主存档生成 `identity.json`、`worlds/<world_id>/world.json` 与导入报告；除首次补建身份外，源存档字节不变 |
| 导入回环 | 同上，导出→导入到新目录 | 田地、库存、布局、厨房、邻居、装饰与包内快照逐项一致 |
| 跨设备语义往返 | 同上，导入后修改并再次导出/导入 | 修改保留，`player_id`／`device_id` 前后一致；库存不重复 |
| 首次导出身份 | 同上，连续两次导出到不同空目录 | 首次导出缺少身份时先写入运行存档的 `identity.json`；两次导出的玩家与设备标识一致，第二次不再改写存档 |
| 损坏包拒绝 | 同上 | `corrupt`，存档与包字节不变 |
| 较新版本拒绝 | 同上 | `rules_version=28` 返回 `newer_rules`，存档不变 |
| 未知格式拒绝 | 同上 | 未知 `format` 返回 `unknown_format`，存档不变 |
| 取消无副作用 | 同上 | 仅预览时存档字节不变，且不创建备份目录 |
| 失败保留原存档 | 同上 | 备份无法建立时导入中止，`farm.json` 字节不变 |
| 重复导入幂等 | 同上 | 第二次导入后主件与身份文件字节一致，库存不叠加 |
| 旧世界保留 | 同上 | `import-backups/world-<id>-N/` 含 `farm.json` 与既有侧车，且该目录本身可被 `FarmStore` 重新读取 |
| 路径安全 | 同上 | 拒绝导出到当前存档内部或非空目录；拒绝从存档目录内部导入；不写源包 |
| 服务测试汇总 | `--headless --path Game --script tests/world_transfer_test.gd` | 72 项通过，0 失败，退出 0 |
| UI 冒烟 | `tests/world_transfer_ui_test.gd` | 18 项通过，0 失败：世界页入口、路径注入绕过对话框、960×600 布局、摘要/范围/备份位置、失败提示、取消与确认信号 |
| 主场景流程 | `tests/world_transfer_scene_test.gd` | 14 项通过，0 失败：真实菜单导出、摘要确认、导入后重建农场、磁盘快照、身份与备份 |
| v27 导入回归 | `tests/v27_importer_test.gd` | 68 项通过，0 失败（可选身份注入未改变原有行为） |
| 包契约回归 | `tests/world_package_test.gd` | 106 项通过，0 失败 |
| 设置界面回归 | `tests/ui_settings_scene_test.gd` | 37 项通过，0 失败（新增世界页未破坏模态尺寸与焦点回归） |
| 存档事务回归 | `tests/farm_store_test.gd` | 109 项通过，0 失败（临时文件、重命名、回读校验与损坏侧车拒绝） |

实际命令（`GODOT` 指向锁定编辑器）：

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
"$GODOT" --headless --path Game --script "$PWD/tests/world_transfer_test.gd"
"$GODOT" --headless --path Game --script "$PWD/tests/world_transfer_ui_test.gd"
"$GODOT" --headless --path Game --script "$PWD/tests/world_transfer_scene_test.gd"
"$GODOT" --headless --path Game --script "$PWD/tests/v27_importer_test.gd"
"$GODOT" --headless --path Game --script "$PWD/tests/world_package_test.gd"
"$GODOT" --headless --path Game --script "$PWD/tests/ui_settings_scene_test.gd"
"$GODOT" --headless --path Game --script "$PWD/tests/farm_store_test.gd"
```

另对 `world_transfer.gd`、`v27_importer.gd`、`game_menu.gd`、`main.gd` 执行 `--check-only`，均退出 0。

## 实现与取舍

- 新增 `Game/farm/world_transfer.gd`：`export_world()` 复用 `v27_importer.import_v27()`，不另造包格式；`prepare_import()` 只读取、解析并校验包，`apply_import()` 才写入。预览结果带包内快照与身份，取消时直接丢弃。
- 导入写入复用 `FarmStore.save()` 的完整校验、临时文件、重命名和回读验证，不复制另一套原子写实现。写入前把现有 `farm.json`、备份、临时件与身份侧车复制到 `import-backups/`；回读不一致时尝试从该备份恢复。
- 包内 `player_id`／`device_id` 直接沿用并写入运行存档旁的 `identity.json`（与 v27 导入器同一格式）。导出时复用该身份；运行存档缺少身份时先补建并持久化一次，再导出，避免每次导出生成新的玩家与设备标识。没有从用户名、路径或硬件派生身份。
- 导入前检查包根与 `worlds/<id>` 两种选择方式；多个世界返回 `ambiguous`。包内 `identity.json` 存在但与信封身份不一致时拒绝，避免混用身份。
- `v27_importer.gd` 增加可选 `identity_override` 与公开 `read_identity()`；两步调用方可以在写入前复用既有身份，原有调用行为不变。
- 设置菜单新增「世界」页，提供「导出世界」「导入世界」。文件选择使用目录模式 `FileDialog`；`export_path_override`／`import_path_override` 可在 headless 中注入路径。导入确认页展示世界摘要、替换范围和旧存档备份位置。
- 导出目标要求为空目录，避免同一目录累积多个历史快照或静默覆盖用户文件；非空目录返回 `existing_output`，由界面提示改选空文件夹。
- 备份目录、身份文件与备份临时目录拒绝符号链接；备份复制后核对 SHA-256，避免沿链接写到运行存档之外。

## 未覆盖

- Windows 端往返未在本机执行。“Windows 创建→Mac 修改→Windows 继续”的语义往返目前只在同一台 macOS 上以两个隔离存档模拟，Q3 跨平台证据仍缺 Windows 实机。
- 原生目录选择对话框只构造并接入信号，未在窗口模式实际点击；headless 冒烟使用注入路径。macOS 上的实际对话框布局与可读性未作为通过证据。
- 没有提供一键“恢复上次导入前世界”的界面。备份目录会显示在摘要中，需要时可按现有 `FarmStore` 目录格式手工恢复；恢复入口仍属后续范围。
- 备份成功后、`FarmStore` 重命名主件失败这一具体时序没有在传输测试中单独注入；该持久化层行为由 `tests/farm_store_test.gd` 的临时件、只读主件与回读失败用例覆盖。
- 导出当前要求选择空目录；不支持反复导出到同一已有目录进行覆盖或清理旧快照。
