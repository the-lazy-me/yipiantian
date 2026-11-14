# M2-03 · macOS 桌面嵌入验收记录

执行日期：2026-11-14。状态：进行中，未完成多屏/Spaces 与托盘退出验收。固定提交：`c54cc68`（桌面控制与场景测试）；原生扩展随后单独提交。环境：macOS 27.0.1 / Apple M4 Pro / Metal 4 / 单屏 3840×2160 像素，缩放 2.0（逻辑 1920×1080）。

## 方案

macOS 没有公开 API 把另一个进程的窗口放到桌面层，因此不再引入独立宿主进程，而是用进程内 GDExtension（`native/macos_desktop`）直接调整本进程 NSWindow：

- 层级：`CGWindowLevelForKey(kCGDesktopWindowLevelKey) + 1`，严格低于桌面图标层、高于壁纸。
- 行为：`CanJoinAllSpaces | Stationary | IgnoresCycle | FullScreenAuxiliary`，`ignoresMouseEvents = YES`，激活策略 `Accessory`。
- 输入：窗口不接收鼠标事件，游戏不再转发桌面点击；macOS 壁纸模式只观赏，不提供原位交互。
- 复核：GDScript 每 0.5 秒读取一次实际层级，被 Godot 窗口样式重置时重新应用。
- 恢复：`detach()` 还原普通层级与默认行为，校验层级回到 0，再还原窗口几何。

## 已核验

| 项 | 证据 | 结果 |
|---|---|---|
| 扩展构建 | `native/macos_desktop/build.sh` | debug/release 均为 universal（x86_64 + arm64），`lipo -verify_arch` 通过 |
| 类加载 | `.local/probe_mac_desktop.gd` 窗口运行 | `class_exists=true`；arm64 与 Rosetta x86_64 均能加载 |
| 层级 | 同上 | 桌面层 `-2147483623`，图标层 `-2147483603`，attach 后 `-2147483622`，位于两者之间 |
| 嵌入场景 | `tests/mac_desktop_scene_test.gd` 窗口运行 | 11 项 0 失败：铺满屏幕、无边框、隐藏菜单与 HUD、禁用游戏输入、层级正确、恢复层级与窗口几何 |
| 快速切换 | `tests/mac_desktop_switching_test.gd` 窗口运行 | 7 项 0 失败：同帧重复进入只附着一次，恢复后重进正常，进入过程中取消可回到普通窗口 |
| 导出包加载 | `scripts/build-macos.sh` 产物，无头启动 + `lsof` | 导出把 dylib 放到 `Contents/Frameworks/` 根目录；应用启动时映射了 `macos_desktop.release.dylib`，无扩展加载错误 |
| 菜单栏入口 | `.local/probe_status.gd` 窗口运行 | 状态栏项创建/隐藏幂等，`take_command()` 初始返回 0；**菜单项点击未验证**（本机辅助功能权限被拒，无法自动点击） |
| 导出包复验（2026-11-15） | 当前工作树重新构建，`lipo` + Mach-O UUID + `lsof` + `DYLD_PRINT_LIBRARIES` | 通过：包内 `Contents/Frameworks/macos_desktop.release.dylib` 为 universal，与工程内库 UUID 一致并实际映射；扩展探针 `system_state()==3`；导出包 `--dev-wallpaper` 首次启动停在画质页，未绕过 |

## 本轮修复

- 恢复流程原先没有同步置 `busy`，调用方会误以为恢复已完成并读到尚未还原的窗口尺寸；现在从调用当帧起就处于忙碌状态，直到层级和几何都还原。
- macOS 扩展类名 `MacDesktop` 与 GDScript 常量同名会触发解析错误；桥接常量改为 `MacDesktopBridge`。
- 导出时 Godot 把 `.dylib` 移到 `Contents/Frameworks/` 根目录，而 `.gdextension` 里 `res://native/macos_desktop/...` 的相对路径仍按原层级查找，首次导出因此加载失败。改为把 dylib 安装到工程根并写成 `res://macos_desktop.<target>.dylib`；构建脚本、忽略规则与导出过滤器同步调整。

## 未覆盖

- 菜单栏“返回窗口/退出游戏”的点击链路未执行：创建、幂等与命令读取已验证，但本机 `AXIsProcessTrusted=false`，无法用 AppleScript/cmux-cua 点击菜单项；需要在允许辅助功能的环境手测一次。
- 导出包只在无头/窗口启动与 `lsof` 层面确认扩展已加载；未在导出包中通过 UI 实际进入壁纸模式。
- Spaces 切换、其他应用全屏、Dock 自动隐藏、多显示器：本机单屏，未验证。
- 锁屏/熄屏/遮挡后的停绘制与恢复：锁屏与熄屏已接入并自动化验证，见[锁屏与熄屏停绘制](RECORD-03-sleep.md)；遮挡仍未实现。
- 功耗与长期驻留：M2-05；本轮没有能效结论。
- 桌面图标上方不遮挡与点击穿透的目视检查未做，仅有 AppKit 属性与层级证据。
- `CGWindowListCopyWindowInfo` 的层级读数会滞后数帧；控制器的复核循环因此可能多调用一次 `reassert`/`detach`，两者幂等，恢复结果以多次采样后的层级为准。
