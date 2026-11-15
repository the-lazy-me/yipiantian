# M4-15 · 世界包携带权威侧车文档（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M4、M4-04 或 M13-03 验收完成。前置：[M4-04 世界搬迁](RECORD-03-move.md)、[M13-03 房间备份](../M13/RECORD-09-room-backup.md)、[数据与网络](../../05-DATA-AND-NETWORK.md)。

## 问题

世界包（`yipiantian.world`）此前只携带农场快照、装饰、社交与自然文档。共享世界的权威事实还有十一份侧车文件：地籍、组织、公共基金、公共工程、部队、参战记录、冲突结算、纠纷、居民、居民意图、决议。导出包不含它们，导入后世界只剩一块农场：地块归属、成员财产、组织与冲突全部归零，M4-04 的“迁移后玩家、好友、财产连续”和 M13-03 的“干净恢复”都无法成立。

这些文件各有自己的信封、版本、上限与校验器，不能合并进农场格式，也不能凭包名推测。本切片把它们作为独立文档随包搬运，并保持“缺失”与“空文档”的区别。

## 边界

- 包格式升到 `FORMAT_VERSION = 4`，新增严格受限的 `sidecars` 文档；`MIN_FORMAT_VERSION` 仍为 1，v1–v3 包照常解析并升级为“没有侧车”，不报错、不补空文档。
- `sidecars` 的键只允许白名单里的十一个文件名；未知名拒绝（`unknown_sidecar`），非对象拒绝（`invalid_sidecar`）。
- 每个侧车的信封 `version` 必须等于其存储自己的 `VERSION`，状态走该存储自己的规则校验器；本层不复制第二套规则。
- 每份侧车有独立字节上限，直接取所属存储的 `MAX_BYTES`：territory 256 KiB、residents 256 KiB、conflicts 1 MiB、其余八份 64 KiB。超限报 `sidecar_too_large`，并按文件名点出。
- 包上限由 4 MiB 提到 16 MiB。合法文档上限之和约 12 MiB（社交 8 MiB + 农场 2 MiB + 冲突 1 MiB + 地籍/居民各 256 KiB + 八份 64 KiB），16 MiB 保证“存档路径能接受的世界一定能导出”，同时仍是单个常量、在解析前检查一次；测试断言“所有存储上限之和 + 1 MiB 信封余量 ≤ 包上限”。
- 包 `world_id`、侧车 `world_id`、目录内 `world-id.txt` 三者必须一致。不一致时导入在写任何字节前以 `sidecar_world_mismatch` 拒绝。
- 不新增抽象、配置项或“将来可能用到”的字段；侧车文件名白名单与上限直接引用既有常量。

## 包格式 v4 形状

```json
{
  "format": "yipiantian.world",
  "format_version": 4,
  "rules_version": 27,
  "world_id": "…", "farm_id": "…", "player_id": "…", "device_id": "…",
  "exported_at_utc_seconds": 0, "committed_sequence": 0,
  "money": {"currency": "COIN", "minor_units": 0},
  "snapshot": {}, "decorations": {}, "social": {}, "nature": {},
  "sidecars": {
    "territory.json":      {"version": 1, "state": {}},
    "organizations.json":  {"version": 1, "state": {}},
    "public_funds.json":   {"version": 1, "state": {}},
    "public_works.json":   {"version": 1, "state": {}},
    "units.json":          {"version": 1, "state": {}},
    "participation.json":  {"version": 1, "state": {}},
    "conflicts.json":      {"version": 1, "state": {}, "applied": {}},
    "disputes.json":       {"version": 1, "world_id": "…", "state": {}, "commands": [], "enforcement": {}},
    "residents.json":      {"version": 1, "world_id": "…", "social": {}, "memories": {}, "invitations": {}, "dialogues": {}},
    "npc_intents.json":    {"version": 1, "state": {}},
    "resolutions.json":    {"version": 1, "world_id": "…", "state": {}, "commands": []}
  }
}
```

侧车文档按存储的真实磁盘形状原样搬运；`residents.json` 信封接受当前六键与历史的四键、五键（无 `invitations`/`dialogues`），未知键拒绝。世界身份来自 `state.world_id`（territory/units/participation/conflicts）或信封 `world_id`（disputes/residents/resolutions）；不含世界身份的组织、基金、工程、意图只做结构校验。

## 导出

1. 读自然文档（既有顺序）。
2. `_read_sidecar_documents()` 逐个白名单文件：先用 `is_link` 判链，再判目录、存在、长度、JSON 解析；缺失则直接跳过，绝不写入空文档。
3. 从侧车和 `world-id.txt` 求世界身份；两者不一致拒绝。
4. 逐份走 `WorldPackage.validate_sidecars({name: doc}, world)`，失败按名返回 `sidecar_corrupt` / `sidecar_unsupported` / `sidecar_too_large` / `sidecar_world_mismatch`。
5. `v27_importer.import_v27(..., sidecars, world_id_override)` 以该身份写包：共享世界的稳定名字取代一次性内容哈希，导入后的地籍/部队/参战 `world_id` 才与信封一致；纯 v27 导入仍用内容派生 id。

导出侧任何一步失败都不落包、不改存档（测试逐项比对目录树）。

## 导入顺序与回滚

1. 预检：包身份、目标目录 `world-id.txt` 与包 `world_id` 一致 —→ 不一致零写入。
2. 备份 `BACKUP_FILES`：农场主/备份/等待文件、身份、社交/自然的主/备份/等待文件、`world-id.txt`，以及十一个侧车主文件与 `<stem>.pending.json`。
3. 农场：`FarmStore.save()` 写入 → 重载逐字段比对；不符 `verify_import` 并回滚。
4. 身份、社交、自然（原顺序）。
5. 侧车：包里有则 `_write_sidecar()`（`.pending` → 读回比对 → 改名），再用所属存储的 `load_state()` 读回验证（`verify_sidecar`）；包里没有则 `_remove_sidecar()` 删除目标旧文件 —— 导入是整世界替换，旧的地籍/组织行属于另一个世界。
6. 任一步失败立即 `_restore_backup()`：有备份的文件按 sha256 校验复制回来；备份里没有的保留名文件删除；链接只删链不跟随；目录树移除。恢复后原世界的字节保持不变。

已发现并在本切片内处理的两点：

- 社交/自然存储写盘时会留下自己的 `.backup.json`；早期 `BACKUP_FILES` 未含它们，部分失败恢复会残留。已把 `SocialStore.BACKUP/PENDING`、`NatureStore.BACKUP/PENDING` 纳入恢复集合。
- 断链对 `FileAccess.file_exists` 不可见；导出扫描、`_remove_sidecar`、`_write_sidecar`、`_pinned_world_id`、`_restore_backup` 都先判 `is_link`。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
for t in world_package_test world_package_sidecars_test v27_importer_test farm_store_test \
         world_transfer_test world_transfer_sidecars_test world_transfer_scene_test \
         world_transfer_ui_test territory_transfer_test resolutions_store_test; do
  perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
    --script "$PWD/tests/$t.gd"
done
```

原始末行：

```text
WORLD_PACKAGE_TEST checks=126 failures=0 root=…/world-package-441900
WORLD_PACKAGE_SIDECARS_TEST checks=74 failures=0 root=…/world-package-sidecars-431642
V27_IMPORTER_TEST checks=69 failures=0 root=…/v27-import-415296
FARM_STORE_TEST checks=123 failures=0 root=…/farm-store-248071
WORLD_TRANSFER_TEST checks=113 failures=0 root=…/world-transfer-435424
WORLD_TRANSFER_SIDECARS_TEST checks=142 failures=0 root=…/world-transfer-sidecars-432764
WORLD_TRANSFER_SCENE_TEST checks=17 failures=0 root=…/world-transfer-scene-421752
WORLD_TRANSFER_UI_TEST checks=18 failures=0 root=…/world-transfer-ui-128157
TERRITORY_TRANSFER_TEST checks=154 failures=0
RESOLUTIONS_STORE_TEST checks=73 failures=0 dir=…/resolutions-store-119462
```

`WORLD_TRANSFER_TEST` 运行中出现一条 `ERROR: Could not create directory: …/save-write-failure/import-backups/…`，是该用例故意注入的写失败路径，不影响结果行。

本机按 CI 的三阶段参数（`create → modify → continue`，每阶段独立目录与包）复跑跨机交接脚本 `tests/world_roundtrip_stage.gd`：

```text
WORLD_ROUNDTRIP_STAGE mode=create checks=7 failures=0
WORLD_ROUNDTRIP_STAGE mode=modify checks=12 failures=0
WORLD_ROUNDTRIP_STAGE mode=continue checks=7 failures=0
```

| 用例 | 检查 |
|---|---|
| 白名单与上限 | v4、`MIN_FORMAT_VERSION=1`、十一个文件名与顺序、非侧车名无上限、各上限在 64 KiB–1 MiB、上限之和 + 1 MiB 余量 ≤ 16 MiB |
| v4 往返 | 序列化不改调用方包、解析回来、逐份侧车规范化文本一致、至少两轮序列化收敛、紧凑 JSON 可解析、世界身份唯一 |
| 旧版本 | v3 升级为“无侧车”、v1 同样；v3 带侧车报 `corrupt`；v4 缺键报 `corrupt`；空字典合法 |
| 拒绝 | 未知文件名、非对象侧车、非对象容器、跨世界（state 与信封）、混合世界 |
| 损坏文档 | 版本不符、状态规则不符、多余 state/envelope 键、乱序 replay journal、纠纷 enforcement、冲突 applied、缺版本、参战空 host |
| 居民信封 | 六/五/四键接受、第七键拒绝、memories 跨世界拒绝 |
| 字节上限 | 单份超存储上限 `sidecar_too_large`、解析恰好等于包上限进入解析器、超 1 字节 `too_large`、超大文件不改字节 |
| 真实目录导出 | 全部十一份侧车随包、格式 4、稳定世界身份、报告列出文件名、逐份内容与包一致 |
| 真实目录导入 | 新目录导入后逐份存在、无 `.pending` 残留、逐份存储 `load_state` 成功、具体事实仍在、再导出内容一致 |
| 导出拒绝 | 损坏/版本不符/跨世界/链接四种夹具：不写包、存档树不变 |
| 缺失保持缺失 | 只有农场的世界导出后侧车为空，导入后目标仍无这些文件 |
| 部分失败回滚 | 在 `resolutions.pending.json` 位置放入断链，导入 `sidecar_write`、`restored=true`、世界树与导入前一致、断链被清除、目录外目标未被创建 |
| 世界身份 | 目标 `world-id.txt` 指向别世界时预检与写入前双重拒绝；导出沿用已固定身份 |

## 未覆盖与残留

- **网络迁移未覆盖**：世界包是目录级导出/导入，权威在线的搬迁仍按 [M4-04](RECORD-03-move.md) 的目录复制与 `world_identity` 描述符进行，本切片没有把侧车接入 WSS 迁移或增量同步。
- **Windows 未覆盖**：符号链接、改名语义与路径分隔只在 macOS 本机验证；Windows 上 `is_link`、`rename_absolute` 的行为未实测。
- **真实跨机未覆盖**：两个真实进程、两种平台之间的导出→传输→导入未测；本轮全部是本机同盘目录。
- **缺客户端提示文案**：`Game/scenes/main.gd` 的 `_world_transfer_message()` 尚未映射 `sidecar_corrupt`、`sidecar_unsupported`、`sidecar_world_mismatch`、`verify_sidecar`、`sidecar_write`、`sidecar_remove`，这些失败会落到底部通用文案。该文件由其他改动占用，本切片未改，需要在场景层补齐。
- **既有缺陷**：`DisputesStore` 的 `world_id` 只在一次成功 `load_state` 后固定；新实例直接 `save_state` 会写出空 `world_id`。导出路径通过读取现有文件规避，但存储本身仍是潜在坑，未在本次范围内修。
- **包内无跨文档一致性校验**：各侧车各自合法即可通过；例如 units 引用的组织不存在、纠纷引用的地块不存在，不在包层检查，由世界启动后的规则决定。当前没有跨文档规则可复用，未新增。
- 侧车随包搬运会放大包体积；16 MiB 上限是当前所有存储上限之和的安全余量，若未来某存储放宽上限，需要同步复核包上限（测试里的“上限之和 + 1 MiB”断言会先失败）。

## 关联

- 搬迁与停写：[M4-04](RECORD-03-move.md)；房间备份：[M13-03](../M13/RECORD-09-room-backup.md)。
- 格式与网络：[05-DATA-AND-NETWORK](../../05-DATA-AND-NETWORK.md)。
- 代码：`Game/farm/world_package.gd`、`Game/farm/world_transfer.gd`、`Game/farm/v27_importer.gd`；测试 `tests/world_package_sidecars_test.gd`、`tests/world_transfer_sidecars_test.gd`。
