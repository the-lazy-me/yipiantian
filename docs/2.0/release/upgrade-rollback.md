> 与 2026-11-15 main 分支（含 cba4597 之后的修复与载荷上限切片）对应的实现状态，未验收

# 升级、回滚与恢复演练

**当前没有自动迁移。2.0 格式变更前需先做恢复演练。** 本文说明现有版本契约、升级前必须留下的证据，以及失败时如何回到上一个可运行状态。恢复入口只在 macOS 上演练过；Windows 命令未在实机执行。

## 1. 当前版本契约

| 文档 | 版本 | 说明 |
|---|---|---|
| 农场 `farm.json` | 27 | 只接受 v27；`migrated` 只会是 `false` |
| 天气 `nature.json` | 2 | 兼容读取 v1，保存时写 v2；这是唯一的旧版本例外 |
| 社交 `social.json` | 2 | 世界目录中的邻里文档 |
| 地籍 `territory.json` | 1 | 世界目录中的占地文档 |
| 设置 `settings.json` | 1 | 界面偏好，与农场进度分离 |
| 玩家档案 `player.json` | 1 | 本机玩家 ID 与名字 |
| 世界包 `world.json` | 格式 4 | `rules_version` 必须为 27；v1–v3 包照常读入并按“没有侧车”处理 |
| 协议 | 1 | 加入时校验双方规则/协议版本 |

关键事实（见 [M13-03 演练](../milestones/M13/RECORD-03-recovery.md)）：

- v26 农场文档被拒绝为 `unsupported`；v28 被拒绝；世界包格式 5 被拒绝为 `newer_format`；`rules_version` 26/28 分别被拒绝。
- `migrated` 字段当前没有产生 `true` 的代码路径。
- 载入损坏主档不会自动回滚；只有存在通过校验的备份时才提供“从备份恢复”，且要玩家/运营者显式选择。
- 新建空目录第一次导入世界包时不会生成 `import-backups/`，没有自动回滚点。
- 存储层要求先 `load_state()` 再 `save_state()`；对未加载的实例直接保存会得到 `not_loaded`。恢复脚本不能跳过加载。

## 2. 升级前检查清单

任何格式、规则或程序版本变更前，逐项完成并留证：

- [ ] 停止游戏和所有服务端进程，确认没有进程还在写存档。
- [ ] 备份完整用户数据目录（不是只备份 `farm.json`）：
  - 本地：`farm-v27/`（含 `farm.json`、`farm.backup.json`、`nature.json`、相册）、`preferences/`、`player/`。
  - 开房：`rooms/world/` 整个目录。
  - 自托管：`--data-dir` 整个目录，另加 `world.key`、`server.crt`、`invite.bin`；`world-id.txt` 随目录一起保留（缺了它，下一次成功启动会按当时传入的 `--world` 补写）。
- [ ] 用游戏内“设置 → 世界 → 导出世界”导出一份世界包到空文件夹，并复制到另一块磁盘。包内含世界、农场、社交、天气与身份记录。
- [ ] 对备份逐文件记录 SHA-256，并记录程序版本、提交号、规则版本。
- [ ] 保留与旧存档匹配的旧程序安装包；回滚不能只换数据。
- [ ] 在干净目录做一次恢复演练：导入世界包，核对农场、装饰、社交、天气、身份五类内容，再注入一次失败确认原文件不被覆盖。
- [ ] 任一项失败就不要升级，先恢复演练环境。

说明：当前界面没有“切换存档目录”的入口，干净目录演练需要开发环境或测试脚本；普通玩家至少应完成整目录备份和世界包导出。

## 3. 快照命令

macOS：

```sh
STAMP=$(date +%Y%m%d-%H%M%S)
DEST="$HOME/farm-upgrade-backup/$STAMP"
mkdir -p "$DEST"
cp -R "$HOME/Library/Application Support/Godot/app_userdata/我有一片田/farm-v27" "$DEST/"
cp -R "$HOME/Library/Application Support/Godot/app_userdata/我有一片田/preferences" "$DEST/"
cp -R "$HOME/Library/Application Support/Godot/app_userdata/我有一片田/player" "$DEST/"
# 如果开过房或自托管，再单独备份 rooms/world 或服务端数据目录
find "$DEST" -type f -exec shasum -a 256 {} \; > "$DEST/SHA256SUMS"
```

Windows：

```powershell
$Stamp = Get-Date -Format yyyyMMdd-HHmmss
$Root = Join-Path $env:APPDATA "Godot\app_userdata\我有一片田"
$Dest = Join-Path $HOME "farm-upgrade-backup\$Stamp"
New-Item -ItemType Directory -Path $Dest -Force | Out-Null
Copy-Item -Recurse (Join-Path $Root "farm-v27") $Dest
Copy-Item -Recurse (Join-Path $Root "preferences") $Dest
Copy-Item -Recurse (Join-Path $Root "player") $Dest
Get-ChildItem $Dest -Recurse -File | Get-FileHash -Algorithm SHA256 |
  Format-Table -AutoSize
```

自托管数据目录先按 `self-host.md` 的只读退役流程冻结再复制：

```sh
STAMP=$(date +%Y%m%d-%H%M%S)
DEST="$HOME/farm-upgrade-backup/$STAMP/world"
mkdir -p "$DEST"
touch /srv/farm/world/read-only
# 等状态文件 read_only=true
touch /srv/farm/world/stop
# 等进程退出且 save=read_only_skipped
rsync -a /srv/farm/world/ "$DEST/"
```

## 4. 回滚步骤

1. 停止新版本的游戏与服务端，避免它继续写新格式。
2. 不删除新目录；把它改名保留，作为故障证据。
3. 整目录还原升级前的快照：`farm-v27/`、`preferences/`、`player/`；开房再加 `rooms/world/`；自托管再加数据目录与三份身份材料。
4. 重新安装/切换到与旧存档匹配的旧程序版本。只回退程序、不回退数据，旧程序会用 `unsupported` 拒绝新格式。
5. 启动并核对日志：
   - 本地：`FARM_LOAD stage=loaded version=27 migrated=false saved=true`，随后能正常进入农场。
   - 天气：没有 `NATURE_LOAD stage=failed`。
   - 服务端：`opened=loaded`，`server-status.json` 为 `state=running`，成员能重新加入。
6. 如果恢复后仍打不开，停止操作，保留原目录，用另一份快照副本重试；不要手改 JSON 或版本号。

回滚验证通过前，不要再次升级，也不要让新版本覆盖还原后的目录。

## 5. 不可逆红线

- **没有自动迁移。** 当前只接受 v27 农场；没有降级器，也没有“先写新格式再读回旧格式”的路径。
- 不要手改 `version`、`rules_version`、`format_version` 试图绕过拒绝。
- 不要把“上一代备份”当成完整快照：`farm.backup.json` 只覆盖农场上一代，社交、天气、地籍、身份和相册不在其中。
- 不要只还原 `farm.json`。天气、社交、地籍、身份必须来自同一时间点的快照，否则世界会自相矛盾。
- 不要删除 `farm.backup.json`、`nature.backup.json`、`social.backup.json`、`territory.backup.json` 或 `*.unreadable.*` 文件；它们可能是唯一的诊断/恢复材料。
- 回滚时不要轮换或删除 `world.key`、`server.crt`、`invite.bin`；换材料会让所有旧加入码失效。
- 不要导入来源不明、格式 5 或 `rules_version` 不是 27 的包；当前会拒绝，不要试图绕过。
- 新目录首次导入世界包没有 `import-backups/`；失败时只能靠你自己保留的包和快照。
- 不要依赖“包导出成功”代替整目录备份：世界包不含服务端身份材料，也不含相册和设置。

## 6. 恢复演练的最低标准

一次合格的演练至少覆盖：

1. 从当前真实存档导出世界包，记录 SHA-256；再导出一次，确认两次包字节一致（演练记录中已证明可复现）。
2. 在干净目录导入，核对农场快照、装饰、社交、天气、身份五类内容逐项相等，`migrated=false`。
3. 注入一次失败（截断包、截断目标主件或写入冲突），确认拒绝发生在覆盖之前，原文件 SHA 不变。
4. 用 `farm.backup.json` 做一次显式恢复，确认损坏原文被另存而不是删除。
5. 最后才在新版本上打开副本，而不是直接打开唯一一份真实存档。

演练记录、命令和证据位置见 [M13-03](../milestones/M13/RECORD-03-recovery.md)。该记录只对应当时的工作树版本，不能替代下一次升级前的重新演练。

## 7. 未验证

- 当前不存在真正的 2.0 格式，本文没有可执行的“升级到 2.0”步骤，只有前置条件和回滚方法。
- 演练使用测试夹具，不是真实玩家存档；未验证真实相册、大量社交记录和长期世界的体积。
- 未在 Windows 实机执行升级/回滚；只在 CI 覆盖同名存储入口的部分用例。
- 未测试导出或导入中途断电、SIGKILL、可移动介质拔出。
- 未测试跨机器、不同文件系统（大小写敏感、权限、符号链接）之间的迁移。
