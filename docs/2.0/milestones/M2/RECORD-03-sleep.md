# M2-04 · macOS 锁屏与熄屏停绘制记录

执行日期：2026-11-14。状态：实现与本机自动化验证完成；真实锁屏/熄屏事件投递未实测。基线提交 `497c1de`（本轮改动在同一提交序列中）。

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
| 嵌入回归 | `tests/mac_desktop_scene_test.gd` | 11 项 0 失败 |
| 快速切换回归 | `tests/mac_desktop_switching_test.gd` | 7 项 0 失败 |
| 绘制量 | 农场场景 `Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME` | 正常呈现约 2028 次/帧；挂起时渲染循环关闭（`is_render_loop_enabled()` 为 false） |
| 状态默认值 | 原生探针 | 正常启动返回 `system_state()==3`（会话活跃、显示器唤醒） |

绘制停止的直接证据是渲染循环关闭；Linux/Windows 上 `WindowActivity` 的既有停绘制行为不变。Windows 桌面前台 `COVERED` 路径仍走原宿主消息，本轮未改。

## 未覆盖

- 没有真实触发锁屏、显示器休眠或系统唤醒：本机多个场景测试并行运行，`pmset displaysleepnow` 会中断它们；事件通知的实际投递与恢复后的画面仍未实测。
- 遮挡（被其他应用完全盖住）没有接入停绘制。桌面层窗口若用最小化/隐藏来观察遮挡，窗口本身不可见后 `occlusionState` 永远为不可见，无法可靠判断何时恢复；需要独立于窗口可见性的覆盖检测，留待后续。
- 深闲 5 分钟后的资源释放未在本记录内到达（沿用 `WindowActivity` 既有路径与其测试）。
- 未测多显示器、Stage Manager、外接显示器热插拔。
- 功耗与长期驻留属于 M2-05，本记录不作能效结论。

## 回退

若原生状态读取不可用（扩展未构建或方法缺失），`system_state()` 返回 3，壁纸保持原样运行；控制器的层级看门狗与既有恢复路径不受影响。
