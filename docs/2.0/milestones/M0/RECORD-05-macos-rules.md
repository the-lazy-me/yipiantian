# M0-05 · macOS 规则与存档夹具执行记录

执行日期：2026-11-14。固定提交：`3260727`（`3260727debf8b63366ad9710e997c93e83a8da32`，`main` HEAD）。引擎：Godot `4.7.2.stable.official.ed1daf0bf`。

## 环境

- macOS 27.0.1（26A434），arm64，Apple M4 Pro，Metal 4。
- 引擎路径：`/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot`。
- 隔离数据目录为 `.local/verification/`，未使用玩家真实存档。原始日志保存在 `.local/verification/macos-rules-3260727/`（Git 忽略）。
- 运行时工作树在 HEAD 之外有未提交改动（`main.gd`、桌面壁纸入口、导出脚本等）。本次套件只加载 `farm/` 与 `settings/` 规则模块，不加载主场景或桌面模块；结论对应这些模块与所用测试脚本。

## 命令

以下均在仓库根目录执行同一入口，按套件替换 `<name>`：

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
"$GODOT" --headless --path Game --script "$PWD/tests/<name>.gd"
```

## 结果

| 套件 | 检查 | 失败 | 退出码 | 进程耗时 | 证据 |
|---|---:|---:|---:|---:|---|
| `farm_state_test.gd` | 385 | 0 | 0 | 0.53 s | `FARM_STATE_TEST checks=385 failures=0` |
| `farm_store_test.gd` | 109 | 0 | 0 | 0.53 s | `FARM_STORE_TEST checks=109 failures=0` |
| `farm_command_test.gd` | 26 | 0 | 0 | 0.24 s | `FARM_COMMAND_TEST checks=26 failures=0` |
| `settings_store_test.gd` | 53 | 0 | 0 | 0.24 s | `SETTINGS_TEST checks=53 failures=0` |
| `headless_world_test.gd` | 14 | 0 | 0 | 0.23 s | `HEADLESS_WORLD_TEST checks=14 failures=0` |
| 合计 | 587 | 0 | — | — | — |

`headless_world_test.gd` 同时写出磁盘信封 `FARM_SAVE stage=complete version=27`，确认无场景单命令链路在 macOS 上落到 v27。

## 告警

- 全部日志无 `SCRIPT ERROR`、`Parse Error` 或非预期 `ERROR:`。
- `farm_store_test.gd` 的 `FARM_STORE WARNING`（`corrupt`、`unsupported`、`changed_on_disk`、`invalid_state`、`not_loaded`、`replace_main`、`unsafe_path`、`verify_*`、`write_*`）由测试主动构造坏档、未知版本、外部改动、只读/写入失败等失败注入触发，属预期告警。
- `settings_store_test.gd` 的 `SETTINGS_STORE WARNING`（`invalid_settings`、`load reason=corrupt/unsafe_path/unsupported`、`not_loaded`、`replace`、`unsafe_path`、`unsupported`、`write`）同样来自预期失败注入。
- 上述套件最终均为 0 失败，未见提示真实缺陷的告警。

## 未覆盖与跳过

- `farm_interaction_test.gd` 未运行：该脚本实例化 `res://scenes/main.tscn`、使用实际窗口尺寸、真实鼠标/焦点事件和 `RenderingServer.frame_post_draw`，不支持 `--headless`，需要显示环境；本轮按任务边界跳过，不做窗口场景证据。
- 本轮未运行任何窗口场景测试，因此“当前 UI 基本种收无回归”未取得本轮 macOS 证据。M1-02 的独立场景检查属于其他工作包，不能代替 M0-05 的双平台同夹具结论。
- 进程耗时仅为纯规则夹具的墙钟时间，不作为性能或启动体验证据。

## 验收状态

**Windows 半侧未在本机执行。** 本记录只证明上述夹具在 macOS 4.7.2 上按预期通过，不能证明两平台输出语义相同，因此 M0-05 的跨平台等价验收尚不完整。M0-05 未验收，不据此修改 `PLAN.md` 或宣称阶段完成。
