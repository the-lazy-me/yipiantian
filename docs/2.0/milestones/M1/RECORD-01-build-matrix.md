# M1-01 · 构建矩阵验收记录（macOS 首个产物）

执行日期：2026-11-14。固定提交：`b3185d7`（含构建脚本与 CI 修正）。引擎与模板：Godot 4.7.2-stable / macOS 导出模板 4.7.2.stable。

## 环境

- 构建机：macOS 27.0.1，Apple M4 Pro，3840×2160，Metal 4。
- 引擎路径 `GODOT_PATH` 指向画布固定的 4.7.2 编辑器；模板目录为用户级 Godot 导出模板。
- 产物目录 `.local/builds/macos/`（Git 忽略）。

## 配置

- `Game/export_presets.cfg` 新增 `macOS` 预设：`architecture=universal`（arm64+x86_64），bundle id `com.yipiantian.farm`，最低系统 arm64 13.00 / x86_64 11.00，`application/icon` 使用 `art/ui/game-icon.icns`，未配置签名与公证。
- `Game/project.godot`：`config/macos_native_icon` 指向同一 icns；`textures/vram_compression/import_etc2_astc=true`，随资源提交的 `.import` 文件已包含 ETC2/ASTC 目标，否则 arm64 导出被拒绝。
- `scripts/build-macos.sh`：相对产物路径先转绝对路径（Godot 将相对导出路径解析到工程目录），导出后 ad-hoc 签名或按 `CODESIGN_IDENTITY` 使用 Developer ID，输出 zip、SHA256SUMS 与 version.json。
- `scripts/godot-macos.sh`：冷导入只对已知的汇文明朝体缓存缺失重试一次，其余错误直接失败。
- `.github/workflows/build-macos.yml`：手动触发，校验固定编辑器/模板 SHA-256 后构建、冒烟、`lipo -verify_arch` 并上传产物；尚未进入自动发布链。

## 结果

| 检查 | 结果 |
|---|---|
| 导出 | 无 ERROR/SCRIPT ERROR/Parse Error；`MACOS_BUILD app_version=0.1.8 engine=4.7.2-stable commit=b3185d7` |
| 清单 | `version.json` 记录 commit `b3185d72640c…`、platform macOS、universal、template 4.7.2.stable、signed ad-hoc、zip SHA-256 `2744e2ea…f705` |
| 无头启动 | 导出的 app `--headless --quit-after 1800` 退出 0，`STARTUP_CHOICE_READY recommendation=standard measured=false` |
| 窗口启动 | 导出的 app 窗口运行于 Metal 4.0 / Forward+，`STARTUP_CHOICE_READY recommendation=standard measured=true`，退出 0 |
| 正常退出 | `tests/exit_cleanup_test.gd` 19 项通过，进程在约 6 秒内经产品退出路径自行结束，无“resources still in use”告警 |
| 通用二进制 | `lipo -info` 显示 `x86_64 arm64`，`lipo <binary> -verify_arch arm64 x86_64` 通过 |

`--quit-after` 强制退出会打印 6 个资源仍在使用，与产品退出路径无关；正常退出无此告警。

## 未覆盖

- 未使用 Developer ID 签名与公证；当前产物只可作开发包，Gatekeeper 需手动放行。
- Windows 构建入口与产物本轮未复跑。
- Intel Mac 实机、macOS 12 及更早版本、Apple Silicon 8GB 机型未验证。
- CI 工作流未在 GitHub 上实际运行。
