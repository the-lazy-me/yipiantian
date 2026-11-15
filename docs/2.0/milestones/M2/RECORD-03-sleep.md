# M2-04 · macOS 锁屏与熄屏停绘制记录

执行日期：2026-11-14；遮挡停绘制补于 2026-11-16。状态：实现与本机自动化验证完成；真实锁屏/熄屏事件投递未实测，遮挡已用独立进程覆盖实测。基线提交 `497c1de`（锁屏/熄屏改动在同一提交序列中）。

## 实现

- 原生扩展新增 `system_state()`：监听 `NSWorkspaceSessionDidResignActive/BecomeActive` 与 `ScreensDidSleep/Wake`、`DidWake`，以两个原子电平（会话活跃、显示器唤醒）记录状态。使用电平而非事件队列，避免锁屏后立刻解锁这类成对事件在两次轮询之间被折叠后永久停在挂起态。
- 通知块只写原子变量，不回调 Godot；观察者在模块卸载或 `shutdown()` 时移除。
- `desktop_wallpaper` 在壁纸模式下每 0.5 秒读取状态；只有会话活跃且显示器唤醒才继续呈现。挂起与恢复复用既有 `visibility_changed` 信号，交给 `WindowActivity` 这个展示调度所有者处理：
  - 挂起：暂停场景树、`RenderingServer.set_render_loop_enabled(false)`、低处理器模式；持续 5 分钟后按既有深闲路径释放可恢复的 3D 资源。
  - 恢复：先发 `presentation_changed(true)`，主场景结算 UTC 时间并重设时钟，再重新铺满屏幕、恢复桌面层级并重新断言窗口行为。
- 壁纸控制器自身不再维护帧率或渲染循环，避免与 `WindowActivity` 争夺展示所有权。

## 验证

| 项 | 证据 | 结果 |
|---|---|---|
| 生命周期场景 | `tests/mac_desktop_lifecycle_test.gd`（窗口运行） | 22 项 0 失败：挂起置位、场景暂停、渲染循环关闭、恢复后循环开启并重新绘制、层级回到桌面层上一级、挂起中退出不残留冻结视口 |
| 遮挡自动化 | `tests/mac_desktop_occlusion_test.gd`（窗口运行，采样注入） | 37 项 0 失败：连续遮挡采样暂停（渲染循环关闭、`visibility_changed(false)`）、连续可见采样恢复、单次抖动不翻转、窗口不可见不当作遮挡、锁屏挂起期间遮挡采样不改状态、遮挡中退出不残留冻结视口或标志 |
| 真实遮挡观察 | 壁纸模式 + 另一个 Godot 进程的原生无边框全屏窗口覆盖 | 见下节；`DESKTOP_OCCLUSION covered=true`，覆盖期间 1 秒 0 帧，关闭覆盖后恢复绘制（1.5 秒 44 帧，约 30 fps 上限） |
| 嵌入回归 | `tests/mac_desktop_scene_test.gd` | 11 项 0 失败 |
| 快速切换回归 | `tests/mac_desktop_switching_test.gd` | 7 项 0 失败 |
| 绘制量 | 农场场景 `Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME` | 正常呈现约 2028 次/帧；挂起时渲染循环关闭（`is_render_loop_enabled()` 为 false） |
| 状态默认值 | 原生探针 | 正常启动返回 `system_state()==3`（会话活跃、显示器唤醒） |

绘制停止的直接证据是渲染循环关闭；Linux/Windows 上 `WindowActivity` 的既有停绘制行为不变。Windows 桌面前台 `COVERED` 路径仍走原宿主消息，本轮未改。

## 遮挡停绘制（2026-11-16 补）

### 实现

- `Game/platform/desktop_wallpaper.gd` 的 macOS 轮询每 0.5 秒采样 `MacDesktop::occlusion_visible`，只在「壁纸模式激活且系统未锁屏/熄屏」时采样。原生绑定本已存在，本轮没有改 `.mm`，也不需要重建扩展。
- 遮挡与锁屏/熄屏不再各自调用 `_set_suspended`：两个原因先写入 `_system_paused` / `_occlusion_paused`，再由 `_apply_suspension()` 合并成一次 `_set_suspended(_system_paused or _occlusion_paused)`。`_set_suspended` 仍是唯一发出 `visibility_changed` 的地方，`WindowActivity` 继续是展示调度所有者，没有第二套暂停机制。
- **去抖**：`_occlusion_step` / `_occlusion_settled` 是纯状态机。与当前状态相反的采样累计到 `OCCLUSION_SAMPLES = 2`（约 1 秒）才翻转；中途出现一次符合当前状态的采样会清零计数。菜单栏下拉、通知横幅或窗口切换的瞬间不会反复暂停/恢复。
- **不可见窗口**：最小化、隐藏前的采样同样是 `occlusion_visible == false`，但那不是遮挡。`_occlusion_step` 接收 `present`，窗口不可见时保持当前状态并清空候选计数，因此最小化不会把壁纸永久钉在暂停态；窗口回来后按正常去抖恢复。锁屏/熄屏期间同样不采样（安全的屏幕本来就没有可见窗口），遮挡状态不会被误判。
- **恢复不抢焦点**：遮挡恢复发生在用户刚把别的应用挪开时，此时前移窗口会抢走用户正在使用的焦点；因此只有锁屏/熄屏恢复才调用 `DisplayServer.window_move_to_foreground()`，遮挡恢复只重新铺满屏幕并重断言桌面层级。既有 `window_move_to_foreground()` 在本机实测会把焦点给回游戏窗口，这是必须区分的原因。
- **可观测**：只在翻转时打印一行 `DESKTOP_OCCLUSION covered=true|false`，不刷屏，也不引入新日志框架。
- 进入壁纸时清空全部遮挡标志；`restore()` 在退出时清空遮挡/系统标志，避免下一次进入继承旧读数。

### 真实遮挡观察（本机）

用另一个 Godot 进程建立原生无边框、不可聚焦、跳屏全屏（3840×2160）窗口覆盖目标屏幕，主进程进入壁纸模式后不再介入：

- 覆盖后约 0.4–0.8 秒原生读数翻为 `false`，生产轮询随后打印 `DESKTOP_OCCLUSION covered=true`；`suspended_changed(true)` 同步到达，`WindowActivity.is_suspended()` 为真，渲染循环关闭。
- 覆盖稳态 1 秒内 `Engine.get_frames_drawn()` 增量为 0。
- 关闭覆盖进程后轮询打印 `DESKTOP_OCCLUSION covered=false`，渲染循环重新开启并恢复绘制；最终代码下 1.5 秒 44 帧，与壁纸 30 fps 上限一致。
- 早期探针曾记录恢复后 1.5 秒 241 帧；该次窗口已拿到焦点、帧率上限不同，不能作为壁纸恢复帧数结论，只说明恢复确实在绘制。

**方法学限制**：同进程内的 `Window(force_native)` 覆盖**不能**可靠触发遮挡。本机多次对照显示，只有另一个进程的窗口（以及被 attach 到同一桌面层级的窗口）才会让 `occlusionState` 翻转；同进程的普通 `Window` 叠加在桌面层级窗口上时原生读数保持 `true`。因此自动化测试使用注入采样证明状态机，真机证据使用独立进程覆盖，两者分别说明，不互相冒充。

### 未覆盖（遮挡）

- 只测试了单屏、本机 M4 Pro / 3840×2160、普通应用窗口遮挡。多屏、Stage Manager、Spaces、全屏应用、Dock/菜单栏悬浮造成的部分遮挡、外接显示器热插拔均未测。
- 遮挡去抖的固定 2 次采样（约 1 秒）是本机经验值；没有对真实用户操作节奏做统计，也没有验证 30 帧上限下的采样抖动。
- `occlusionState` 是 AppKit 私有实现驱动的公开只读属性；官方文档没有承诺窗口层级或 accessory 激活策略下的更新细节。已实测本机行为，未验证其他 macOS 版本。

## 未覆盖

- 锁屏、显示器休眠或系统唤醒仍没有在真实事件投递下触发：本机多个场景测试并行运行，`pmset displaysleepnow` 会中断它们；事件通知的实际投递与恢复后的画面仍未实测。（遮挡已在 2026-11-16 补测，见上节。）
- 深闲 5 分钟后的资源释放未在本记录内到达（沿用 `WindowActivity` 既有路径与其测试）。
- 未测多显示器、Stage Manager、外接显示器热插拔。
- 功耗与长期驻留属于 M2-05，本记录不作能效结论。

## CI

`tests/mac_desktop_occlusion_test.gd` 是窗口测试，依赖 macOS 原生扩展、真实美术与显示服务器，未登记进 `.github/workflows/rule-tests.yml`。既有 `mac_desktop_lifecycle/scene/switching_test` 同样未登记，且 CI 的 macOS runner 没有构建原生扩展；本机证据不能当作 CI 已执行。

## 回退

若原生状态读取不可用（扩展未构建或方法缺失），`system_state()` 返回 3，壁纸保持原样运行；控制器的层级看门狗与既有恢复路径不受影响。
