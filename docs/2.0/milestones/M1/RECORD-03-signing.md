# M1-04 · 安装与签名流程核验记录

执行日期：2026-11-14。环境：macOS 27.0.1（26A434）、Apple M4 Pro、Xcode 位于 `/Volumes/Disk-1tb/Applications/Xcode.app`、`notarytool 1.1.2 (41)`。

本轮只完成本机在无 Apple 开发者凭据条件下可验证的部分，**没有执行公证提交，也不能把本记录当作发行验收**。M1-04 仍未验收；干净设备安装、升级和公证发行包仍缺证据。

## 当前产物

`.local/builds/macos/`（Git 忽略，可能被并行构建覆盖）：

| 项 | 值 |
|---|---|
| 提交 | `ee787da699f219842125278d055dd2a3ae934a22`（`version.json`） |
| 版本／引擎／模板 | app `0.1.8` / `4.7.2-stable` / `4.7.2.stable` |
| 架构 | universal（`x86_64 arm64`） |
| 签名 | `signed: ad-hoc` |
| zip SHA-256 | `837109355834e0a3303d7c386568181e7ec006034514b38eb92af2f26ea505a1` |
| 包内签名 CDHash | `6044cab00a779cdcbe34ac75d342789e98b4257b` |
| 产物时间 | app `2026-11-14T23:17:22+0800`，zip `23:17:43+0800` |

`SHA256SUMS.txt` 与实际 zip 摘要一致。该产物是**开发包**，不是可公开发行包。

该目录正被并行重建。本页数值固定为上述 `ee787da` 产物；若 `version.json` 或摘要已变化，应重新执行本页命令，不能把这里的摘要和结论直接套到新产物上。

## Apple 当前要求

以下结论来自 Apple 官方文档（2026-11-14 查阅）和本机 Xcode 手册：

- **必须用 Developer ID 签名。** Apple 明确排除 ad hoc、Mac Distribution、Apple Developer 和本地开发证书，并要求所有可分发的可执行文件具备有效签名。Developer ID 证书需要 Apple Developer Program 团队 Account Holder 才能在开发者账户中生成。
- **必须启用 Hardened Runtime。** 公证服务要求 app 和命令行目标启用 hardened runtime。
- **必须带安全时间戳。** 签名时需包含 secure timestamp。
- **不能直接上传 `.app`。** 需先用 `ditto -c -k --keepParent` 打成 zip；`notarytool` 只接受 zip、UDIF 磁盘映像和签名的 flat installer package。
- **用 `notarytool` 提交并等待结果。** `altool` 自 2023-11-01 起不再被公证服务接受；Xcode 14 或更新版本的 `notarytool` 是当前入口。凭证可使用 Apple ID + app-specific password + Team ID，或预先用 `notarytool store-credentials` 保存的 keychain profile；Apple 建议用 keychain 引用避免脚本中出现明文密码。
- **成功后必须 staple。** zip 本身不能 staple；应 staple 其中的 app，再重新打 zip 分发。未 staple 时 Gatekeeper 可在线获取票据，但离线首次启动无法确认。
- **Gatekeeper 校验 Developer ID 与公证票据。** macOS Catalina 起默认要求公证；公证过的软件在首次启动对话框中会显示 Apple 已检查且未发现恶意软件。用户仍可在“系统设置 → 隐私与安全性”中手动放行未识别开发者的 app，这属于用户覆盖，不是分发方通过校验。
- 公证不是 App Review；公证通过也不等于内容、许可或玩法验收。

官方来源：

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Developer ID](https://developer.apple.com/developer-id/)
- [About Gatekeeper](https://support.apple.com/en-us/102445)
- [Open a Mac app from an unidentified developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unidentified-developer-mh40616/mac)
- [Using app-specific passwords](https://support.apple.com/en-us/HT204397)
- 本机手册：`man notarytool`、`man stapler`、`man spctl`、`man codesign`

## 本机核验结果

对上述 `我有一片田.app` 与 zip 使用只读命令检查，未修改原产物。

### 签名与完整性

```text
$ codesign -dv --verbose=4 "我有一片田.app"
Format=app bundle with Mach-O universal (x86_64 arm64)
CodeDirectory v=20400 ... flags=0x2(adhoc)
CDHash=6044cab00a779cdcbe34ac75d342789e98b4257b
Signature=adhoc
TeamIdentifier=not set
```

- 嵌套库 `Contents/Frameworks/macos_desktop.release.dylib` 同样是 ad-hoc，`TeamIdentifier=not set`。
- `codesign -d --entitlements -` 只输出可执行文件路径，没有 entitlements。
- 未启用 hardened runtime：签名 flags 中没有 runtime 标志；当前 ad-hoc 分支也没有 secure timestamp。

```text
$ codesign --verify --deep --strict --verbose=2 "我有一片田.app"
我有一片田.app: valid on disk
我有一片田.app: satisfies its Designated Requirement
exit=0
```

这只能证明包内签名自洽、资源封印完整；ad-hoc 签名没有可信身份，不能证明来源，也不能满足公证或 Gatekeeper 的分发要求。

### Gatekeeper 与 Apple 就绪检查

```text
$ spctl -a -vv -t exec "我有一片田.app"
我有一片田.app: accepted
override=security disabled
exit=0

$ spctl --status
assessments disabled
exit=1
```

**本机 Gatekeeper 评估被全局关闭**，所以 `accepted` 来自 `security disabled` 覆盖，不是策略通过。该结果不能作为 Gatekeeper 验证证据；本轮没有修改这项系统安全设置。

Apple 的 `syspolicy_check` 给出真实的分发前结论：

```text
$ syspolicy_check distribution "我有一片田.app"
App has failed one or more pre-distribution checks.
Adhoc Signed App            Severity: Warning
Notary Ticket Missing       Severity: Fatal
exit=70

$ syspolicy_check notary-submission "我有一片田.app"
App has failed one or more pre-notarization checks.
Adhoc Signed App            Severity: Warning
exit=70
```

结论：产物签名自洽、可被本机 `codesign` 接受，但按 Apple 当前规则不能分发，也没有公证票据。

### zip 与隔离属性

```text
$ shasum -a 256 "我有一片田.0.1.8.macOS.zip"
837109355834e0a3303d7c386568181e7ec006034514b38eb92af2f26ea505a1  我有一片田.0.1.8.macOS.zip

$ xattr -l "我有一片田.app"      # 无输出
$ xattr -l "我有一片田.0.1.8.macOS.zip"  # 无输出
```

zip 顶层恰好一个 `.app`；解包后的 app 再次 `codesign --verify --deep --strict` 通过（exit 0）。本机构建产物没有 `com.apple.quarantine` 属性。

隔离属性测试在 APFS clone 上进行，未修改原 app：

```text
$ cp -cR "我有一片田.app" "$work/我有一片田.app"
$ xattr -w com.apple.quarantine "0083;1794670053;Safari;" "$work/我有一片田.app"
$ xattr -p com.apple.quarantine "$work/我有一片田.app"
0083;1794670053;Safari;
$ codesign --verify --deep --strict "$work/我有一片田.app"
exit=0
$ spctl -a -vv -t exec "$work/我有一片田.app"
accepted
override=security disabled
```

可以确认：quarantine 属性可写入并保留，且不影响签名完整性。由于本机评估子系统已关闭，**无法在本机观察 Gatekeeper 的双击拦截/“打开”覆盖流程**；本轮没有打开该 app，也没有启用 Gatekeeper。默认 Gatekeeper 机器上的实际拦截行为仍属未验证。

## 开发包与可发行包

| 特征 | 当前开发包 | 可公开发行包所需 |
|---|---|---|
| 签名身份 | ad-hoc（`Signature=adhoc`，无 Team ID） | Developer ID Application 证书，带 Team ID |
| 安全时间戳 | 无 | `codesign --timestamp` |
| Hardened Runtime | 未启用 | 启用并配置必要 entitlements |
| 公证 | 未提交 | `notarytool submit --wait` 返回 `Accepted` |
| 票据 | 无 | staple 到 app，再重新打 zip |
| Gatekeeper | 本机被 `security disabled` 覆盖；经下载/传输带 quarantine 的默认机器会拒绝 | 默认设置下 `spctl` 通过，首次启动显示已公证 |
| 用途 | 本机开发、内部冒烟 | 对外分发、干净设备安装与升级 |

## 公证脚本

新增 `scripts/notarize-macos.sh`：

- 只接受 `.app` 或 `.zip`；`.app` 在提交前打成临时 zip，不修改原 app；提交被接受后才 staple。
- `.zip` 输入保持原样；解包、staple 其中的 app，并输出 `<名称>.notarized.zip`。
- 凭证只从环境变量读取：`NOTARY_PROFILE`，或同时提供 `APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD`。脚本不写入任何凭证；优先使用 `NOTARY_PROFILE`，env 密码路径仍会把密码作为命令行参数传给 `notarytool`。
- 提交使用 `xcrun notarytool submit --wait --output-format json`，检查返回状态必须为 `Accepted`；之后执行 `xcrun stapler staple`、`xcrun stapler validate`、`codesign --verify --deep --strict` 和 `spctl -a -vv -t exec`。
- 若本机 Gatekeeper 评估被关闭，脚本仍会执行 `spctl`，但会额外警告该结果不是真实策略检查。

本机可执行的检查：

```text
$ /bin/bash -n scripts/notarize-macos.sh       # exit 0（bash 3.2.57）
$ ./scripts/notarize-macos.sh                  # 用法提示，exit 2
$ bash scripts/notarize-macos.sh /tmp/does-not-exist.app   # input not found，exit 1
$ bash scripts/notarize-macos.sh "$PWD/README.md"          # 扩展名错误，exit 1
$ env -u NOTARY_PROFILE -u APPLE_ID -u APPLE_TEAM_ID -u APPLE_APP_PASSWORD \
    bash scripts/notarize-macos.sh ".local/builds/macos/我有一片田.app"
notarize-macos: missing notary credentials: set NOTARY_PROFILE, or all of APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD
# exit 1

$ env -u NOTARY_PROFILE -u APPLE_APP_PASSWORD APPLE_ID=foo APPLE_TEAM_ID=bar \
    bash scripts/notarize-macos.sh ".local/builds/macos/我有一片田.app"
notarize-macos: missing notary credentials: ...   # 缺 APPLE_APP_PASSWORD，exit 1
```

对 `.zip` 输入的顶层 app 识别逻辑用实际产物单独验证：`top-level-app-count=1`，解包 app 的 `codesign --verify` 返回 0。

本机未安装 `shellcheck`，未运行该工具；脚本按 `set -euo pipefail`、变量加引号和 bash 3.2 兼容写法编写。脚本的提交、staple 与公证后 `spctl` 路径没有在真实凭据下执行过。

**未执行**：真实的 `notarytool submit`、`stapler staple`、`stapler validate`，以及公证后 `spctl` 在启用 Gatekeeper 机器上的验证。本机没有 Apple 开发者凭据，也没有向 Apple 公证服务发送任何内容。

## 未验证项

- **签名**：没有 Developer ID 证书，未验证证书链、Team ID、hardened runtime 和 secure timestamp。
- **公证**：未提交、未得到 `Accepted` 状态、未获取票据；本记录不主张公证通过。
- **票据**：未执行 `stapler staple` / `validate`。
- **干净设备安装**：没有第二台干净 Mac，本机 Gatekeeper 评估又被关闭，无法复现默认安全设置下的首次启动。
- **升级**：没有旧版本安装与升级路径证据。
- **quarantine 实际拦截**：只能确认属性可写入和签名不受影响；默认 Gatekeeper 下的双击拦截/放行流程未观察。
- **Windows 包**：不在本记录范围；M1-04 的 Windows 行为仍缺证据。
- **发行包内容**：公证后重新打 zip 的产物、下载传输后的 quarantine 传播和最终分发摘要未验证。

以上未验证项完成前，M1-04 的“干净设备启动与升级记录齐备”不能判定通过，当前产物只能作为开发包使用。
