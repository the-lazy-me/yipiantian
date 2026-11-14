# M0-03 · 标识、序列化与世界包契约验收记录

执行日期：2026-11-14。固定提交：`ee787da`（M0-03 实现提交；验收执行时基线为 `3260727`）。规则版本：FarmState v27；世界包信封 `format_version=1`、`rules_version=27`。现有 v27 存档路径未改动。

> 后续 M0-04 在同一 `format_version=1` 下补入 `decorations` 字段；本记录的 102 项测试对应提交 `ee787da`，当前信封与导入结果见 [M0-04 记录](RECORD-04-v27-import.md)。

## 环境与输入

- macOS，Apple M4 Pro，Metal 4。
- Godot 4.7.2-stable（`.godot-version`）。
- 隔离数据目录：`.local/verification/world-package-*` 与 `farm-store-*`；无玩家真实存档参与。

## 改动

- `Game/farm/world_package.gd`：纯函数式世界包校验与序列化。校验格式/规则版本、四个标识、UTC 导出时间、已提交序号、金额表示和 v27 快照；通过 FarmState 完整校验快照并返回规范化副本；不读写任何存档路径。
- `tests/world_package_test.gd`：覆盖合法往返、较新格式/规则拒绝、损坏/截断/超限输入、非法标识/时间/序号/金额、重复导入一致，以及拒绝后原始文件字节与 SHA-256 不变。
- `docs/2.0/05-DATA-AND-NETWORK.md`：新增“M0-03 契约（目标包信封 v1）”。
- `docs/2.0/milestones/M0/PLAN.md`：M0-03 链接本记录。

## 结果

| 检查 | 命令 | 结果 |
|---|---|---|
| 包契约测试 | `"$GODOT" --headless --path Game --script "$PWD/tests/world_package_test.gd"` | 102 项通过，0 失败，退出 0 |
| 农场规则回归 | `"$GODOT" --headless --path Game --script "$PWD/tests/farm_state_test.gd"` | 385 项通过，0 失败，退出 0 |
| 存档回归 | `"$GODOT" --headless --path Game --script "$PWD/tests/farm_store_test.gd"` | 109 项通过，0 失败，退出 0 |
| 新模块语法 | `"$GODOT" --headless --path Game --check-only --script "$PWD/Game/farm/world_package.gd"` | 退出 0 |

其中 `GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot`。`farm_store_test.gd` 中预期的 `FARM_STORE stage=unsupported` 告警来自既有拒绝路径，最终计数为 0 失败。

## 覆盖范围

- 合法包序列化、重新解析，快照经 FarmState 规范化后与输入语义一致；再次序列化文本稳定。
- `format_version=2`、`rules_version=28` 分别返回 `newer_format`、`newer_rules`；更低版本返回 `unsupported_*`。
- 空输入、截断 JSON、非对象 JSON、缺字段/多字段、非对象快照和违反 FarmState 规则的快照均被拒绝。
- 标识为空、含空白/路径分隔符/非 ASCII、类型错误或超长时拒绝；时间/序号为负、非整数或超过 2^53−1 时拒绝；金额为小数、负数、超界、币种格式错误、缺字段或多余字段时拒绝。
- 同一文本重复导入产生相同包数据和相同序列化文本。
- 较新版本和截断文件被拒绝后，原文件文本与 SHA-256 均未变化。

## 未覆盖与后续

- Windows 同夹具未执行；双平台等价结论留 M0-05。
- v27 真实存档到 2.0 的字段迁移未实现，留 M0-04；本阶段快照仍是 v27 FarmState 形状。
- 对象清单、事件尾部、内容摘要、联网、账号与经济活动未实现；新增字段须递增 `format_version` 并定义兼容规则。
