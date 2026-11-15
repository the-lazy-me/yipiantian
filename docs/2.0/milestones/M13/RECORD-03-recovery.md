# M13-03 · 恢复与升级演练（本机证据）

日期：2026-11-15。状态：本机演练完成并通过，**不表示 M13-03 或 M13 验收完成**。本记录只描述用现有入口实际执行的一次完整演练，未修改任何产品代码、规则、测试或工作流；所有演练数据在 `.local/recovery-drill/`（`.local/` 已在 `.gitignore` 第 3 行忽略）。

## 结论

| 步骤 | 内容 | 结果 |
|---|---|---|
| 1 | 从 v27 夹具走 `world_transfer.export_world()` 导出世界包 | 通过（9 项断言，退出码 0） |
| 2 | 干净目录 `prepare_import()` + `apply_import()`，比对五类文档 | 通过（21 项断言，退出码 0） |
| 3 | 截断包 / 截断主件 / 损坏 identity pending 的拒绝与恢复 | 通过（19 项断言，退出码 0） |
| 4 | `import-backups` 失败回滚、`farm.backup.json` 显式恢复 | 通过（35 项断言，退出码 0） |
| 5 | 仅接受 v27、`migrated=false`、拒绝 v26/v28 | 通过（16 项断言，退出码 0） |
| 回归 | 现有 `tests/world_transfer_test.gd` | `WORLD_TRANSFER_TEST checks=113 failures=0` |

原件 6 个文件在全部步骤前后 SHA-256 逐字节一致（见下）；未发生任何原件覆盖。

## 环境与基线

| 项 | 值 |
|---|---|
| macOS | 27.0.1（26A434），arm64（Apple M4 Pro） |
| Godot | `4.7.2.stable.official.ed1daf0bf`，仅 `--headless` |
| 仓库 HEAD | `7e0fd96c9e8196a76bd7953a1c82f88000bb8494` |
| 分支 | `main` |
| 工作树 | 含并行任务的未提交改动；本任务未修改任何受版本控制文件 |

并行改动与本演练入口的关系（重要）：

| 文件 | 状态 | SHA-256（演练时工作树） |
|---|---|---|
| `Game/farm/world_transfer.gd` | 未修改（HEAD 版本） | `99fe34869429b1d9f83aa7ee1bf81abb976aeb87eabc3b356924421dd54c994f` |
| `Game/farm/world_package.gd` | 未修改 | `9ee89eff1082cea7abd6dca8a3e95bea1391bcff6243213a20c5f4ff3c28a2b8` |
| `Game/farm/v27_importer.gd` | 未修改 | `e05c81afd599daa361f8db755eef8b16d80a822edcb6cb8574efd86089f40ae9` |
| `Game/farm/farm_store.gd` | 并行任务已改 | `8fb006f38e93e49916623726c3505d0e5ac43e9cbe9032a335b278cd3f558518` |
| `Game/farm/farm_state.gd` | 并行任务已改 | `9d0579e8ceba18069549b7d7b0b36a67a014faa4e7f684a86c347e7cf4081f26` |
| `Game/farm/nature_store.gd` | 并行任务已改 | `98e8557fd574ae337efbdb66baf2df55ceeb5c5663adec87bfb860bdf335956b` |
| `Game/social/social_store.gd` | 并行任务已改 | `a8a8762602d321b86eadc69eb15706b13b431f410e1043832d68ebb74247704d` |
| `tests/world_transfer_test.gd` | 未修改 | `a0d81886cd6b98d57f3e2aa9664c1c8d86e63b9383aa0a3d885609b8d54a4611` |

上述入口文件最后修改时间：`world_transfer.gd`、`world_package.gd`、`v27_importer.gd`、`tests/world_transfer_test.gd` 在演练前（07:01–15:52）已固定；`farm_store.gd`（15:56）、`farm_state.gd`（16:30）、`nature_store.gd`（16:31）、`social_store.gd`（16:31）由并行任务更新。

- 五步演练在 16:41–17:12 执行，晚于上述全部写入，期间文件未再变化；演练针对的是表格中记录的工作树版本。
- 回归测试 `WORLD_TRANSFER_TEST checks=113` 在 16:28 执行，早于 `farm_state.gd`/`nature_store.gd`/`social_store.gd` 的最后一次写入。因此这条回归只覆盖那三个文件改动前约 2–3 分钟的版本；五步演练本身是改动后的版本，两者不能互相代替。
- `headless_world.gd`、`world_host.gd`、`world_server.gd` 的并行改动没有改变导出/导入入口的调用方式，因此本演练未受影响，也不需要绕道其他入口。

## 夹具

来源：运行现有夹具测试生成的真实 v27 存档（未手写 JSON）：

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 120 "$GODOT" --headless --path Game \
  --script "$PWD/tests/world_transfer_test.gd"
```

末行：`WORLD_TRANSFER_TEST checks=113 failures=0 root=.../.local/verification/world-transfer-305160`

从 `.local/verification/world-transfer-305160/save-a` 复制 6 个文件到 `.local/recovery-drill/source-original/` 作为“原件”，并记录：

| 文件 | SHA-256 |
|---|---|
| `farm.json` | `2b89e72ac6e4fb9a6c1b2a72706a0b6cf1c39599f5aa2602e14f0cf6568bf0f4` |
| `farm.backup.json` | `2b89e72ac6e4fb9a6c1b2a72706a0b6cf1c39599f5aa2602e14f0cf6568bf0f4` |
| `social.json` | `99c70aca081ec7299c2df9d0284f68922b0e638f9a13b63404f6c2f5b4377f2c` |
| `social.backup.json` | `99c70aca081ec7299c2df9d0284f68922b0e638f9a13b63404f6c2f5b4377f2c` |
| `nature.json` | `b1f49dd97ecdc49ee148b2cf12813bc84e0a43edaf6042eb5bd763815e4dec22` |
| `identity.json` | `848a1055b84607b93f87ab26a805e5e77bfe51aa981a2f901d10c501aed6895b` |

夹具内容：农场文档 `version=27`，7 个地块共 106 格，已种 3 格（收获后 `field_03/cell_06` 为空、`field_04/cell_06` 成熟），`inventory.greens=1`、`harvested.greens=1`，7 只动物、4 个厨房任务、0 建筑、`transaction.sequence=0`、`economy.sequence=0`；装饰 6 项（`bench`、`tea_table` 已解锁）；社交 2 名玩家（阿青、小满，互为联系人）；`nature.json` 为 `{"seed":111222,"rules_version":2}`，信封 `version=2`；`identity.json` 为 `player_395f3ef4…` / `device_616c1967…`。

演练脚本放在 `.local/recovery-drill/drill_0N_*.gd`，通过 `--script` 绝对路径运行，不进入仓库测试集（按本任务边界，未新增测试或规则）。

## 步骤 1 · 导出

```sh
"$GODOT" --headless --path Game --script "$PWD/.local/recovery-drill/drill_01_export.gd"
```

末行：`DRILL_01_EXPORT checks=9 failures=0`

关键原始输出：

```text
WORLD_TRANSFER stage=export result=ok
DRILL_01 source_unchanged_after_export=true
DRILL_01 package_sha256=411987412ca3c08447f0e00f9527e9446694c8666b8dceb54814c24f3bf6f6c8
DRILL_01 world_id=accce8a8dfaad60d33a136dced8e7b90069d91fe3bd3237df74dfd482dfe29c4
DRILL_01 farm_id=459e89ab20af3f5cc721e9886ffa63799365cd97dd74100494fd6218b5eb5b0d
DRILL_01 format_version=3 rules_version=27
DRILL_01 package_snapshot_sha256=d459caf40f31fd418f9738df5250adb9ae9a7ccbcff5f9b53955270fd6cc85e8
DRILL_01 package_decorations_sha256=2597a43fb6a4a3fe767210ce91ae3d876abbfeb3ecee20bd60900e6f27f772e9
DRILL_01 package_nature={"rules_version":2,"seed":111222}
DRILL_01 reexport_sha256=411987412ca3c08447f0e00f9527e9446694c8666b8dceb54814c24f3bf6f6c8
```

- 包路径 `export/worlds/accce8a8…/world.json`，SHA-256 `411987412ca3c08447f0e00f9527e9446694c8666b8dceb54814c24f3bf6f6c8`。
- 第二次导出到不同目录，包字节完全相同（`reexport_sha256` 相同），说明包不含真实墙钟，可作为可复核的固定输入。
- 导出前后原件目录哈希树一致；`identity.json` 由首次导出建立（本夹具已存在，内容未变）。

## 步骤 2 · 干净目录导入与比对

```sh
"$GODOT" --headless --path Game --script "$PWD/.local/recovery-drill/drill_02_import.gd"
```

末行：`DRILL_02_IMPORT checks=21 failures=0`

```text
WORLD_TRANSFER stage=prepare result=ready
DRILL_02 prepare_has_existing_save=false
DRILL_02 prepare_writes_nothing=true
FARM_SAVE stage=complete version=27
WORLD_TRANSFER stage=import result=ok
DRILL_02 import_backup_path=
DRILL_02 nature_written=true
DRILL_02 migrated=false
DRILL_02 farm_equals_package=true
DRILL_02 decorations_equals_package=true
DRILL_02 social_equals_package=true
DRILL_02 social_players=2 messages=0 grants=0
DRILL_02 nature_seed=111222 rules_version=2
DRILL_02 identity_player_id=player_395f3ef47ca61f716caaa5e53bbb30da
DRILL_02 identity_device_id=device_616c19676e8de05b842fe1d63de33ce0
DRILL_02 imported_files=4
```

关键字段与计数（原件 vs 导入）：

| 字段 | 原件 | 导入 |
|---|---|---|
| `fields` / `cells` | 7 / 106 | 7 / 106 |
| 已种 / 成熟 | 3 / 3 | 3 / 3 |
| `inventory.greens` / `harvested.greens` | 1 / 1 | 1 / 1 |
| 动物 / 厨房任务 / 建筑 | 7 / 4 / 0 | 7 / 4 / 0 |
| `transaction.sequence` / `economy.sequence` | 0 / 0 | 0 / 0 |
| `season` / `bags` 拥有者 / 布局地块 | daily / 0 / 6 | daily / 0 / 6 |
| 社交玩家 / 消息 / 授权 | 2 / 0 / 0 | 2 / 0 / 0 |
| `nature.seed` / `rules_version` | 111222 / 2 | 111222 / 2 |
| `identity.player_id` / `device_id` | `player_395f…` / `device_616c…` | 相同 |
| `migrated` | — | `false` |

- 农场快照与装饰与包内文档**字典级相等**（不只是计数相等）；社交与自然文档同样相等；身份与包 `player_id`/`device_id` 一致。
- `prepare_import()` 不创建目标目录、不改包；`apply_import()` 不改源包、不改原件。
- 新目录首次导入产出 4 个文件（`farm.json`、`social.json`、`nature.json`、`identity.json`），`backup_path` 为空、`import-backups` 不存在——符合“新世界没有旧副本”的设计，但这也意味着**首次导入没有自动回滚点**。

## 步骤 3 · 副作用：拒绝与恢复

```sh
"$GODOT" --headless --path Game --script "$PWD/.local/recovery-drill/drill_03_sideeffects.gd"
```

末行：`DRILL_03_SIDEEFFECTS checks=19 failures=0`

```text
WORLD_TRANSFER stage=prepare result=corrupt          # A 截断包
DRILL_03 A truncated_package result=false kind=corrupt

WORLD_TRANSFER stage=prepare result=ready            # B 目标主件被截断
WORLD_TRANSFER stage=import result=corrupt
DRILL_03 B apply result=false kind=corrupt

WORLD_TRANSFER stage=prepare result=ready            # C 恢复正确文件后重试
FARM_SAVE stage=complete version=27
WORLD_TRANSFER stage=import result=ok
DRILL_03 C restored_apply result=true kind=imported
DRILL_03 C target_keys=14 inventory=1
```

| 场景 | 注入 | 结果 |
|---|---|---|
| A 截断世界包 | 取包前 640 字节复制为 `reject-package/world.json` | `prepare_import` 返回 `corrupt`；目标目录未创建；源包 SHA 不变 |
| B 截断目标主件 | 目标副本的 `farm.json` 与 `farm.backup.json` 写成 `{"version": 27, "farm": {"fields": {` | `apply_import` 返回 `corrupt`；截断文件 SHA 不变；不创建 `import-backups`；源包与原件的 SHA 均不变 |
| C 恢复后重试 | 从干净导入副本恢复 4 个文档，写入截断的 `identity.import.pending.json`，删除 `identity.json` | 导入成功；损坏的 pending 被丢弃；身份与包一致；`inventory.greens=1` 保留 |

B 的拒绝发生在写任何目标字节之前：`apply_import` 先 `FarmStore.load_state()` 校验目标，再加锁式备份；因此“拒绝且不覆盖”不是靠事后回滚，而是根本没有进入写阶段。C 证明 `identity.import.pending.json` 不是可被采纳的输入，重试会以包内身份重建。

## 步骤 4 · 备份与回滚

### 4a 导入中途失败 → 回滚到导入前副本

```sh
"$GODOT" --headless --path Game --script "$PWD/.local/recovery-drill/drill_04_backup_rollback.gd"
```

末行：`DRILL_04_BACKUP_ROLLBACK checks=35 failures=0`

```text
DRILL_04 harvested=field_04/cell_06
DRILL_04 target_pre greens=2 farm_sha=1f9849e14b9067970f04fd31c01a327bbe63e52aceccf07c46e77f2003c099a6
DRILL_04 planned_backup=.../rollback-target/import-backups/world-accce8a8dfaa
DRILL_04 failed_apply result=false kind=social_io restored=true backup=.../import-backups/world-accce8a8dfaa
DRILL_04 backup_farm.json=1f9849e14b9067970f04fd31c01a327bbe63e52aceccf07c46e77f2003c099a6
DRILL_04 retry result=true kind=imported
```

做法：先把目标世界做成与包不同（用真实 `FarmState.harvest()` + `FarmStore.save_state()` 再收一篮，`greens` 1→2，`farm.json` SHA `2b89…` → `1f98…`），再用一个同名目录挡住 `social.pending.json` 的写入，使写阶段在“农场已替换、社交未写入”处失败。

| 检查 | 结果 |
|---|---|
| 失败原因 | `social_io`（具名阶段，不是笼统失败） |
| 回滚标记 | `restored=true` |
| 回滚后活动文档 | 全部与导入前逐文件 SHA 相同（含 `farm.json=1f98…`） |
| `import-backups/world-accce8a8dfaa/` | 保留；`farm.json`、`social.json`、`nature.json`、`identity.json` 均与导入前相同 |
| 源包 | SHA 不变 |
| 移除注入后重试 | `imported`，世界被包内容替换（`greens=1`） |

`social.backup.json` 在回滚后等于原件 `99c7…`；本次夹具的 `social.json` 与 `social.backup.json` 内容本就相同，因此这一步无法区分“上一代社交备份是否被压掉”，只作为代码阅读项登记（见末节）。

### 4b 主件损坏 → `farm.backup.json` 显式恢复

```text
DRILL_04 damaged_load ok=false kind=recovery_available source=farm.backup.json
FARM_LOAD stage=recovered source=farm.backup.json version=27
DRILL_04 recover ok=true kind=recovered
DRILL_04 unreadable_archive_count=1
```

- 夹具经真实 `FarmStore` 连续提交两代生成 `farm.backup.json`；把 `farm.json` 截断为 `{"version": 27, "farm": {`。
- `load_state()` 返回 `recovery_available`，**不自动回滚**；损坏主件保持原样直到调用方显式 `recover()`。
- `recover()` 后 `farm.json` 与 `farm.backup.json` 字节相同（`2b89…`），损坏原文另存为 `farm.unreadable.<pid>.<us>.json`（本次 1 个），符合“保留原件供诊断”。
- 另有一次非预期观察：对新目录直接 `FarmStore.new(dir).save_state(...)` 返回失败（未 `load_state()` 准入）。这是存储层的正确拒绝（`not_loaded`），不是演练目标，但运维脚本需要先加载再保存。

## 步骤 5 · 升级边界

```sh
"$GODOT" --headless --path Game --script "$PWD/.local/recovery-drill/drill_05_upgrade.gd"
```

末行：`DRILL_05_UPGRADE checks=16 failures=0`

```text
DRILL_05 accepted ok=true kind=loaded migrated=false
DRILL_05 FarmStore.VERSION=27 WorldPackage.RULES_VERSION=27
DRILL_05 v26 ok=false kind=unsupported
WORLD_TRANSFER stage=export result=unsupported_version
DRILL_05 v26_export ok=false kind=unsupported_version
DRILL_05 v28 ok=false kind=unsupported
WORLD_TRANSFER stage=export result=newer_version
DRILL_05 v28_export ok=false kind=newer_version
DRILL_05 package_rules28 ok=false kind=newer_rules
DRILL_05 package_rules26 ok=false kind=unsupported_rules
DRILL_05 package_format4 ok=false kind=newer_format
```

| 输入 | 结果 |
|---|---|
| 现有 v27 存档 | 接受，`migrated=false`（没有发生迁移） |
| `version=26` 的农场文档 | `load_state` 拒绝 `unsupported`；导出拒绝 `unsupported_version`；副本字节不变 |
| `version=28` 的农场文档 | `load_state` 拒绝 `unsupported`；导出拒绝 `newer_version`；副本字节不变 |
| 包内 `rules_version=26` / `28` | 分别拒绝 `unsupported_rules` / `newer_rules` |
| 包内 `format_version=4` | 拒绝 `newer_format` |
| 当前信封 | `format_version=3`，`rules_version=27` |
| `V27Importer.KNOWN_FARM_KEYS` | 14 项；含 `economy`，不含 `territory`（地籍由独立的 `territory.json` 承载） |

说明：v26/v28 副本只改了信封 `version` 数字，用于验证拒绝路径；**没有伪造任何新 schema，也没有实现迁移器**。`migrated` 字段在 v27 只会是 `false`，当前代码没有可产生 `true` 的路径。

### 2.0 格式升级前的恢复前置条件

依据本次演练与既有契约（[05-DATA-AND-NETWORK](../../05-DATA-AND-NETWORK.md)「导入与版本演进」、[ADR-003](../../decisions/ADR-003-storage.md)、[M3-03](../M3/RECORD-03-commit-recovery.md)）：

1. **先有可回滚的完整世界快照**：`farm.json`（含 `transaction` 与 `economy`）+ `social.json` + `nature.json` + `identity.json`，逐文件记录 SHA-256；`farm.backup.json` 只能证明上一代，不能替代整份快照。
2. **先导出一次世界包并保留**：包内含身份与世界标识，可在同版本程序上重建世界；本次证明包字节可复现（两次导出 SHA 相同）。
3. **世界服务端另存身份材料**：`world.key`、`server.crt`、`invite.bin` 与 `server-status.json` 不在世界包内；密钥丢失后无法为后续代次签名，升级前必须单独备份（[ADR-004](../../decisions/ADR-004-transport.md) 已列为未实现项）。
4. **回退程序只能用匹配版本快照**：当前实现对 v26 返回 `unsupported`、对 v28 返回 `unsupported`，不会强行读取；回退必须同时回退程序与数据，不能只换包。
5. **先在干净目录演练**：本次的做法（导出 → 干净目录导入 → 注入失败 → 回滚 → 重试）应作为升级前固定步骤；首次导入没有 `import-backups`，所以“升级前就有旧副本”必须由操作者自己保证。
6. **保留策略待发布时确定**：`import-backups/` 每代占一份完整副本，当前没有清理或数量上限；长期运行的体积增长未测。

## 未验证项

- **Windows 实机**：全部步骤只在本机 macOS（arm64）headless 执行；Windows 上的路径大小写、重命名替换与只读介质未复跑。CI 覆盖同名入口的部分用例，但本次未在 Windows 运行。
- **断电 / SIGKILL 中途**：本次的失败注入是“目标路径被占用/截断文档”，不是进程在导出或导入中途被杀。提交边界中断见 [M3-03](../M3/RECORD-03-commit-recovery.md)；导出/导入中途终止未测。
- **跨机迁移**：未在两台机器、真实网卡、非回环地址之间搬运目录或包；文件系统不同的行为（大小写敏感、权限、符号链接）未覆盖。
- **身份材料轮换**：`world.key`/`server.crt` 的轮换、密钥丢失后的恢复、设备会话令牌撤销均未执行；当前代码也没有轮换入口。
- **真实玩家存档**：使用测试夹具（`.local/verification` 生成物），未使用本机真实 `user://farm-v27`。
- **窗口路径**：全部 headless，未验证导入后的启动界面、错误提示与用户可见反馈。
- **大世界与体积**：夹具约 32 KB，未测接近 `FarmStore.MAX_BYTES`（512 KiB）的世界、导出耗时或备份保留增长。
- **`social.backup.json` / `nature.backup.json` 的代次行为**：本次夹具中两组 main/backup 内容相同，未能区分回滚是否覆盖上一代备份（见下条代码阅读发现）。

## 需要登记的内容

1. **`world_transfer.BACKUP_FILES` 不含 `social.backup.json`、`nature.backup.json`**：导入前备份代次只保存 `social.json`/`nature.json` 当前代；`SocialStore.save_state()` 会用自己的规则滚动 `social.backup.json`。本次未取得区分性证据，需决定是否把这两个侧车纳入备份清单，或明确“导入只承诺活动文档”的语义。
2. **首次导入无回滚点**：目标目录没有旧世界时 `backup_path` 为空且不建 `import-backups`；恢复文档应写明“新世界导入失败无自动回滚，需保留包本身”。
3. **`save_state()` 需先 `load_state()`**：运维/恢复脚本不能对新实例直接保存，否则 `not_loaded`；建议写入 M13-05 的操作指南。
4. **升级前置条件**（上节 1–6 条）需要并入 M13-05 玩家/自托管指南；目前只在本文档。
5. **演练脚本未固化为仓库测试**：按本任务边界未新增测试文件。若要成为门禁，需在 `tests/` 新建用例并在 CI 运行；当前证据只在本机、只对应上面记录的工作树版本。

## 产物位置

```text
.local/recovery-drill/
  source-original/            原件副本（6 文件，SHA 见上）
  source-original.sha256      原件的 SHA-256 清单
  export/worlds/<world_id>/world.json   导出的世界包
  import-clean/               干净目录导入结果（4 文件）
  reject-package/ reject-target/        步骤 3 的拒绝场景
  rollback-target/import-backups/…      步骤 4a 的回滚场景与备份代次
  store-recovery/             步骤 4b 的 farm.backup.json 恢复
  upgrade-v26/ upgrade-v28/   步骤 5 的版本拒绝场景
  drill_01_export.gd … drill_05_upgrade.gd
  logs/drill_01.log … drill_05.log, logs/world_transfer_test.log
```

`.local/` 已在 `.gitignore` 中忽略，以上内容不会进入提交。
