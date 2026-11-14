# M2-02 · 模式状态机验收记录

执行日期：2026-11-15。状态：切片完成，不表示 M2 或三模式验收完成。实现基线提交 `be09071`（本记录与测试同一提交序列）。

## 现有实现边界

三模式的呈现状态由三个所有者分工，不各自复制逻辑：

- `platform/desktop_wallpaper.gd`：桌面层挂载/恢复的协议与 `active`/`busy` 状态；`enter()` 在 `busy` 或已激活时直接返回，不排队第二次转换。
- `atmosphere/window_activity.gd`：唯一帧率与停绘制调度者（`set_wallpaper`、`set_wallpaper_interacting`、`set_wallpaper_visible`、深闲）。
- `scenes/main.gd`：一个 `farm_state` 写入者；切换时只做“结束输入手势 → 收尾表现状态 → 恢复后结算时间”。

“轻量桌面”目前没有独立状态机：产品只有普通窗口和桌面壁纸两种呈现形态，轻量交互通过壁纸模式下的 `interacting` 子状态表达。本记录不为尚不存在的第三形态造状态机。

## 验收项与证据

新用例 `tests/mode_switching_scene_test.gd`（macOS 实窗，`--audio-driver Dummy`，隔离目录 `.local/verification/mode-switch-*`）：

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 175 "$GODOT" --audio-driver Dummy --path Game \
  --script "$PWD/tests/mode_switching_scene_test.gd"
```

结果：`MODE_SWITCHING_SCENE_TEST checks=33 failures=0`，退出码 0，无退出时资源泄漏告警。用例在真实主场景上挂载真实桌面层组件，先武装一个工具与一次未完成的按压/拖拽，再执行三轮往返与一轮连续双击式切换：

| 验收关注点 | 断言 | 结果 |
|---|---|---|
| 输入结束 | 进入后工具、调色板、待定按压与拖拽均为空；`gui_disable_input` 为真 | 通过 |
| 待确认命令 | 武装的工具与选中格在切换前不产生任何 `farm_changed`；进入、往返、重复切换后农场快照与磁盘主件都等于切换前的同一版本 | 通过 |
| 资源释放 | 壁纸期间 HUD 隐藏；`WindowActivity` 报告非前台（固定 30 fps 上限） | 通过 |
| 恢复同步 | 恢复后 HUD 显示、输入恢复；离开期间推进 7200 秒后，恢复把作物成长结算到当前时间 | 通过 |
| 声音行为 | 壁纸期间音频按“非前台”处理（循环与动作静音）；恢复后与窗口实际焦点一致 | 通过 |
| 快速来回 | 连续两次进入只发生一次挂载，`busy` 在完成后为假；连续两次恢复回到普通窗口；全程不提交、不分叉 | 通过 |
| 单写者 | 所有轮次后 `load_state()` 读回与内存快照一致，未出现第二个存档版本 | 通过 |

上一轮记录提到“快速切换不重复提交”需要实例化主场景并驱动真实桌面层，本用例补上了这一段；它不覆盖锁屏/遮挡进入的挂起路径（属 M2-04）与 Windows 宿主进程路径（`desktop_wallpaper` 的非 macOS 分支）。

## 未覆盖

- 该用例依赖 macOS 桌面扩展与窗口，不能进无头 CI；Windows 的宿主进程切换路径仍只有既有 `mac_desktop_switching_test` 之外的零散覆盖，未按本用例重做。
- “不丢工具取消”只证明切换时清空武装状态，不证明玩家在切换前尚未提交的语义被撤销（产品契约是未点击即未发生，切换不代提交）。
- 没有真实用户鼠标在切换瞬间的竞态注入；连续调用的用例覆盖了重入，但不覆盖 `enter()` 正在 `await` 时收到恢复请求的窗口。
- 未测切换期间保存失败、磁盘只读或设置写入失败的组合路径。
- 未测 8 小时驻留后的模式切换；长期驻留属 M2-05。

## 关联

- 模式与能耗口径：[平台边界与低功耗验证方案](../../architecture/PLATFORM-ENERGY.md)；[M2 PLAN](PLAN.md) M2-02。
- 运行形态裁决：[ADR-002](../decisions/ADR-002-runtime.md)。
- 配对测量：[M2-05 测量记录](RECORD-02-macos-measure.md)；锁屏停绘制：[M2-04](RECORD-03-sleep.md)。
