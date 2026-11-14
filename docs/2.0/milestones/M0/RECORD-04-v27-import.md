# M0-04 · v27 一次性导入与幂等验收记录

执行日期：2026-11-14。验收基线：`392eead`（记录初稿时为 `da4ef60`，期间仅有其他工作流提交）；改动提交 `497c1de`。规则版本：FarmState v27；世界包信封 `format_version=1`。现有 v27 存档读写路径未改动。

## 环境与输入

- macOS，Apple M4 Pro，Metal 4。
- Godot 4.7.2-stable（`.godot-version`）。
- 隔离数据目录：`.local/verification/v27-import-*`；v27 夹具由现有 FarmStore 写入，无玩家真实存档参与。

## 改动

- `Game/farm/world_package.gd`：v1 信封增加 `decorations`；用 DecorationState 校验并交叉核对厨房摆放约束；新增 `canonical_text()`，序列化时按字典键递归排序；公开 `valid_identifier()`。
- `Game/farm/v27_importer.gd`：只读 v27 `farm.json` 主件，校验版本与现有 FarmState/DecorationState；生成隔离的 `identity.json`、`worlds/<world_id>/world.json` 与 `import-report.json`；内容哈希派生 ID、幂等写入、未知字段报告和原件保护。
- `tests/world_package_test.gd`：覆盖新增 `decorations` 字段及非法装饰。
- `tests/v27_importer_test.gd`：真实 v27 夹具的逐项字段核对、身份复用、重复导入、损坏/较新版本拒绝、未知字段和原件 SHA-256 检查。
- `docs/2.0/05-DATA-AND-NETWORK.md`：补充 `decorations` 字段和 M0-04 一次性导入规则。
- `docs/2.0/milestones/M0/PLAN.md`：M0-04 链接本记录。

## 结果

| 检查 | 命令 | 结果 |
|---|---|---|
| 信封与装饰 | `"$GODOT" --headless --path Game --script "$PWD/tests/world_package_test.gd"` | 106 项通过，0 失败，退出 0 |
| v27 导入 | `"$GODOT" --headless --path Game --script "$PWD/tests/v27_importer_test.gd"` | 68 项通过，0 失败，退出 0 |
| 农场规则回归 | `"$GODOT" --headless --path Game --script "$PWD/tests/farm_state_test.gd"` | 385 项通过，0 失败，退出 0 |
| 存档回归 | `"$GODOT" --headless --path Game --script "$PWD/tests/farm_store_test.gd"` | 109 项通过，0 失败，退出 0 |

`GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot`。`farm_store_test.gd` 的预期 `unsupported` 告警来自既有拒绝路径，最终 0 失败。

## 覆盖范围

- 地块、库存、产出计数、邻居、布局、厨房与时间、动物、记忆、季节和装饰逐项与 v27 源快照相等；测试同时核对具体库存、邻居轮次/礼物、装饰槽位/朝向、地块结算时间和厨房任务起止时间。
- v27 无金额与序号，导入分别初始化为 `COIN/0` 和 `0`，报告中注明。
- `world_id`/`farm_id` 由规范化 `{farm, decorations}` 的规范 JSON 内容 SHA-256 加域前缀派生；测试直接重算并比对。
- 同一源第二次导入返回 `changed=false`，不新建世界目录，包与报告字节、身份文件和源文件 SHA-256 全部不变，库存不叠加。
- 较新版本、旧版本、截断 JSON、缺失源、非法农场和更深层未知字段均被拒绝，拒绝后源字节不变；未知顶层及 `farm`/`decorations` 顶层键写入报告并排除出包，报告保留键名和值。
- 导入只写隔离输出目录；输出根不得等于源目录、不得位于源目录下、不得是 `user://farm-v27` 或已含 `farm.json` 的目录。

## 冲突、边界与未覆盖

- **长期世界身份冲突**：M0-04 按任务要求把内容哈希写入 `world_id`/`farm_id`，用于同一源导入去重。这与 05 中 World ID 作为可变世界长期稳定身份的目标语义冲突；本记录只将其限定为一次性导入键，未把内容哈希声明为 2.0 持久世界身份。后续接入持久世界身份时需要稳定 ID 映射，不能把内容变化解释为新世界。
- **v1 字段补齐**：M0-03 已提交的 v1 没有 `decorations`；M0-04 在 `format_version=1` 下补入该字段，因为 05 明确要求迁移装饰。当时没有真实 v1 外部包；若已有外部 v1 包，应视为不兼容并递增版本，不能静默接受。
- `player_id`/`device_id` 是首次导入时用随机字节生成并持久化的会话占位标识，不是已验证的身份密钥或设备授权会话；身份密钥方案仍按 05 在 P0/M4 验证。
- 更深层未知键不做猜测性剥离，直接拒绝并保留原件；只有接受导入时，报告才可能包含未知键。
- 只读取 v27 主件，不自动选择备份或临时件；Windows 未执行，双平台等价留 M0-05。
- 未接入 UI、`main.gd` 或正式 `user://` 存档路径；未实现事件尾部、内容摘要或联机能力。
