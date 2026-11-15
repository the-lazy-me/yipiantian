# M13 · 桌面导出预设与开发产物记录（RECORD-01）

日期：2026-11-15。状态：本机导出与 macOS 冒烟通过；CI 工作流尚未在远端执行。产物只作开发用途，未签名、未公证、未发布。

## 范围与结论

- 引擎与模板：Godot 4.7.2-stable，导出模板 4.7.2.stable。
- 游戏版本：`Game/project.godot` 的 `config/version="0.1.8"`，主场景 `res://scenes/startup.tscn`。未升级到 2.0.0。
- 目标：macOS universal（arm64 + x86_64）与 Windows x86_64 各一个开发预设，输出到仓库根 `build/`。
- 结果：两个预设本机导出退出码均为 0；macOS 无头启动到 `STARTUP_COMPLETE`。Windows 产物只做结构与资源检查，未在 Windows 实机运行。
- 发行权属仍未核清（[RIGHTS.md](../../research/RIGHTS.md)），本轮不发布、不对外分发。

## 导出预设

`Game/export_presets.cfg` 原已存在。本轮只把两个开发预设的默认输出改到 `build/`，并在 Windows 预设排除 macOS 专用 GDExtension；未改运行时代码。

| 预设 | 平台/架构 | 版本 | 默认输出 | 签名/公证 |
|---|---|---|---|---|
| `macOS` | macOS，universal（arm64 + x86_64） | 0.1.8（bundle id `com.yipiantian.farm`） | `../build/macos/我有一片田.app` | `codesign/codesign=0`，`notarization/notarization=0` |
| `Windows Desktop` | Windows，x86_64 | 0.1.8.0（产品名 `我有一片田`） | `../build/windows/我有一片田.exe` | `codesign/enable=false` |

进一步配置：

- macOS：`export/distribution_type=1`，最低系统 x86_64 11.00 / arm64 13.00，界面图标 `res://art/ui/game-icon.icns`。
- Windows：`binary_format/embed_pck=false`（产物为 exe + pck），图标 `res://art/ui/game-icon.ico`。
- Windows 预设 `exclude_filter` 增加 `native/macos_desktop/*`。否则 `all_resources` 会把仅含 `macos.*` 库配置的 GDExtension 打进 Windows 包，导出时产生“未找到 x86_64 库”警告；排除后复测为零警告。
- `.gitignore` 增加 `/build/`，开发产物不入库。

## 模板来源与校验

引擎：本机既有 4.7.2 编辑器，`--version` 输出 `4.7.2.stable.official.ed1daf0bf`。

| 文件 | URL | SHA-256 | 字节 |
|---|---|---|---|
| macOS 编辑器 zip | `https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_macos.universal.zip` | `c58a24e31d720be9d62f60cb5627c4e695fb72f21b0cfe1bc9ccaa9a3b3ba63e` | 170,622,178 |
| 导出模板 tpz | `https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz` | `f298490b8d44d934be425a5a65a51bf15f422428b229a06a6e11d9ffea248011` | 1,281,349,702 |

模板下载到 `.local/templates/Godot_v4.7.2-stable_export_templates.tpz`，实测哈希与上表一致。安装目录为 `~/Library/Application Support/Godot/export_templates/4.7.2.stable/`，从 tpz 取出 `macos.zip`、`windows_release_x86_64.exe` 与 `version.txt`；`version.txt` 为 `4.7.2.stable`。

## 本机实测

命令（`$GODOT` 为上述编辑器，`alarm 900` 作超时保护）：

```bash
perl -e 'alarm shift; exec @ARGV' 900 "$GODOT" --headless --path Game --export-release "macOS" "$PWD/build/macos/我有一片田.app"
perl -e 'alarm shift; exec @ARGV' 900 "$GODOT" --headless --path Game --export-release "Windows Desktop" "$PWD/build/windows/我有一片田.exe"
```

原始结果：

- macOS：`EXIT=0`；日志 1268 行，`ERROR:` / `SCRIPT ERROR:` / `Parse Error:` / `WARNING:` 均为 0；末两行为 `[ DONE ] savepack`、`[ DONE ] export`。
- Windows：`EXIT=0`；日志 1259 行，`ERROR:` / `SCRIPT ERROR:` / `Parse Error:` / `WARNING:` 均为 0；末行为 `[ DONE ] savepack`；exe 与 pck 均存在。
- 日志在 `.local/m13-export/macos-export2.log`、`.local/m13-export/windows-export2.log`。

macOS 冒烟：

```bash
"build/macos/我有一片田.app/Contents/MacOS/我有一片田" --headless --quit-after 1800
```

`EXIT=0`，日志包含 `STARTUP_COMPLETE`，无缺失资源或 GDExtension 加载错误。开头有一条既有存档提示 `WARNING: FARM_STORE stage=changed_on_disk error=1`，随后 `FARM_LOAD stage=loaded version=27` 正常载入；`--quit-after` 强制退出时另有 6 条 “resources still in use at exit”，与产品退出路径无关（同 M1 记录）。

## 产物清单

| 产物 | 字节 | 结构/类型 |
|---|---:|---|
| `build/macos/我有一片田.app`（目录） | 约 709 MiB（`du -sh`） | App bundle，版本 0.1.8 |
| …/`Contents/MacOS/我有一片田` | 170,132,160 | Mach-O universal：x86_64 + arm64 |
| …/`Contents/Resources/我有一片田.pck` | 571,364,016 | Godot 资源包 |
| `build/windows/我有一片田.exe` | 109,301,760 | `PE32+ executable (GUI) x86-64` |
| `build/windows/我有一片田.pck` | 570,662,572 | Godot 资源包 |

其他检查：

- Windows exe 的 PE 资源含 UTF-16 的 `FileVersion` / `ProductVersion` / `ProductName` 与 `0.1.8.0`、`我有一片田`。
- macOS 可执行文件 `lipo -info` 为 `x86_64 arm64`；Info.plist 的 `CFBundleShortVersionString` / `CFBundleVersion` 均为 0.1.8，`CFBundleIdentifier=com.yipiantian.farm`。
- 两个 pck 都能检索到主场景 `res://scenes/startup.tscn` 引用，以及约 438 条不同的 `res://art/` 资源路径（pck 路径表无分隔符，个别条目尾部会带上后续二进制字节），说明主场景与 `Game/art` 资源已打包。
- Windows pck 不含 `macos_desktop.gdextension`；本机含原生构建的 macOS 包包含该扩展，CI 干净检出不会包含。
- SHA-256：macOS 可执行 `6135ad137facbb26cd73a5f7f7d541d334a84fc81650e870ef075cdd14a129cd`，macOS pck `2e99624e09c231e4bd84f5ad97d6b18c6aaea7f9332b556cf75cf0f767bfcd42`，Windows exe `2a55a65a227a06fe965ab5b3dce15703d8221072dbdcb9ac10460e14e135b6a8`，Windows pck `f5b91552ec7532a35a4d7bb510f1818397dbc7ce4a7901550e21517864ea1745`。

## 签名与模板既有签名

本轮未执行任何签名、公证或发布命令；预设中代码签名与公证均为 0。

需要区分：macOS 导出模板本身带有 Godot 上游的 Developer ID 签名，导出后该签名仍附着在可执行文件上（`codesign -dv` 显示 `Authority=Developer ID Application: Prehensile Tales B.V. (6K46PWY5DM)`，`Identifier=godot.macos.template_release.arm64`，`Sealed Resources=none`）。这是模板属性，不是本轮签名或公证的结果，也不能当作可分发发行包的签名证据。

## CI 工作流

新增 `.github/workflows/build.yml`，仅 `workflow_dispatch`，无 `push` / `pull_request` 触发，无 secrets，`permissions: contents: read`。

步骤：

1. `actions/checkout@v4`，`lfs: true` 检出美术，`persist-credentials: false`。
2. 从官方 release 下载 4.7.2 编辑器与 tpz，按上表 SHA-256 校验；解压编辑器并安装 macOS/Windows 导出模板。
3. `mkdir -p build/macos build/windows`；先经 `scripts/godot-macos.sh Export` 完成冷导入（含项目字体缓存缺失的一次重试）和 macOS 导出，再直接调用引擎导出 Windows。
4. 检查可执行文件、pck 与 macOS bundle；干净检出不应含 `*.dylib`。
5. macOS 无头 `--quit-after 1800` 冒烟，要求出现 `STARTUP_COMPLETE` 或 `STARTUP_CHOICE_READY`。
6. `actions/upload-artifact@v4` 上传 macOS `.app`、Windows `.exe` 与 `.pck`，保留 14 天。

本机无法执行远程 workflow，也未推送或触发。已做：

- 用 PyYAML 6.0.3 解析 YAML，触发条件读回为 `workflow_dispatch`，步骤与 runner 正常；`actionlint` / `shellcheck` 本机不可用，未安装。
- 模拟干净检出：临时移走本机的 `Game/macos_desktop.*.dylib` 与 `Game/native/macos_desktop/`（随后恢复），重新导出到 `build/ci-sim/`。结果 `EXPORT_EXIT=0`、包内 dylib 数 0、`SMOKE_EXIT=0` 且日志含 `STARTUP_COMPLETE`。该模拟证明工作流的无扩展导出路径可运行，但不等于 GitHub Actions 已通过。
- 模拟中发现并修正两点：Windows 导出前必须创建目标目录；Windows 预设排除 macOS GDExtension 后消除缺失库警告。

## 禁用项

- 未签名、未公证、未做 Gatekeeper 兼容处理。
- 未创建 release、未上传公开产物、未接触 secrets、未推送提交或触发远程 workflow。
- 未新增运行时插件、依赖或自动更新。

## 未覆盖

- Windows 实机启动与画面：本机为 macOS，只验证 PE 结构、pck 资源与体积。
- macOS 实机窗口启动、Intel Mac、macOS 12 及更早版本。
- Developer ID 签名、公证、自动更新与发布链路。
- 干净检出的 CI 尚未在 GitHub 实际运行；工作流通过性只有本地模拟和 YAML 解析证据。
- CI 不构建 `macos_desktop` GDExtension，干净检出产物不含 macOS 壁纸桌面扩展；本机产物含该扩展。
- 资产与代码的发行权属仍未核清，见 [RIGHTS.md](../../research/RIGHTS.md)。

## 复现

```bash
export GODOT_PATH=/path/to/Godot.app/Contents/MacOS/Godot
unzip -j Godot_v4.7.2-stable_export_templates.tpz \
  'templates/macos.zip' 'templates/windows_release_x86_64.exe' 'templates/version.txt' \
  -d "$HOME/Library/Application Support/Godot/export_templates/4.7.2.stable"
mkdir -p build/macos build/windows
"$GODOT_PATH" --headless --path Game --export-release "macOS" "$PWD/build/macos/我有一片田.app"
"$GODOT_PATH" --headless --path Game --export-release "Windows Desktop" "$PWD/build/windows/我有一片田.exe"
```
