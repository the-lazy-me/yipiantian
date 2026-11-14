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

## 本轮修复

- 恢复流程原先没有同步置 `busy`，调用方会误以为恢复已完成并读到尚未还原的窗口尺寸；现在从调用当帧起就处于忙碌状态，直到层级和几何都还原。
- macOS 扩展类名 `MacDesktop` 与 GDScript 常量同名会触发解析错误；桥接常量改为 `MacDesktopBridge`。

## 未覆盖

- 托盘/菜单栏退出：依赖原生状态栏项，待补；当前只能由游戏代码或退出流程触发恢复。
- 导出包内加载：待导出产物验证（`.dylib`/`.gdextension` 是否进入包内并签名）。
- Spaces 切换、其他应用全屏、Dock 自动隐藏、多显示器：本机单屏，未验证。
- 锁屏/熄屏/遮挡后的停绘制与恢复：M2-04。
- 功耗与长期驻留：M2-05；本轮没有能效结论。
- 桌面图标上方不遮挡与点击穿透的目视检查未做，仅有 AppKit 属性与层级证据。
