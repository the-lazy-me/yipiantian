# M11-03 · 决议效果接入世界权威并持久化

执行日期：2026-11-16。状态：切片完成，不表示 M11-03 或 M11 验收完成。前置：[M11 PLAN](PLAN.md)、[RECORD-05 · 规则决议](RECORD-05-resolutions.md)、[RECORD-12 · 规则决议权威](RECORD-12-resolutions-authority.md)、[RECORD-14 · 规则决议效果](RECORD-14-resolution-effects.md)。

## 问题

RECORD-14 冻结了税费与公共建设的纯换算，但 `apply()` 只在测试里被调用：`HeadlessWorld` 不加载效果文档，`execute_resolution()` 不登记已生效的决议，重启后没有任何持久化水位。效果因此只是“能算”，世界既不能在激活后宣告费率变化，也无法阻止重启后重复应用或让已撤销的规则重新计税。

本切片把效果文档接进世界权威：新增严格 sidecar，激活成功后登记并落盘，打开世界时补齐缺失的效果，视图顶层暴露只读费率与系数。仍然不做界面、不改摘要、不接真实收入结算。

## 边界

- 新增 `Game/world/resolution_effects_store.gd`、`tests/resolution_effects_authority_test.gd` 与本记录。
- 修改 `Game/world/resolution_effects.gd`（只把 `_consistent()` 改名为公开 `consistent()`，算法语义不变）、`Game/world/headless_world.gd`（加载、补齐、`execute_resolution()`、`resolutions_view()`）、`Game/farm/world_package.gd`（白名单、限额、验证、交叉一致性）、`Game/farm/world_transfer.gd`（备份集合与回读校验）、`Game/world/world_host.gd`（仅“世界未打开”默认视图补 `effects` 键）。
- 更新 `tests/resolution_authority_test.gd`、`tests/world_package_sidecars_test.gd`、`tests/world_transfer_sidecars_test.gd`、`tests/resolution_network_test.gd` 的必要断言，并在 CI 补登本切片新测试与此前漏登记的 `resolution_effects_test`。
- 新存储同样复制完整的 `_safe_paths()` 守卫（祖先链、`MAIN`、`PENDING` 都不能是符号链接），并加入 `tests/sidecar_store_guards_test.gd` 的 `STORE_NAMES`，与其余 13 个存储一起覆盖同一组用例。
- 未修改 `Game/scenes/main.gd`、`Game/farm/farm_command.gd`、`Game/ui/memory_page.gd`、`Game/world/world_invite.gd`、`Game/ui/resolutions_panel.gd`、`Game/world/world_projection.gd`、`Game/world/resolutions_store.gd`、`Game/world/resolution_state.gd`。
- 不升 `FORMAT_VERSION`：`sidecars` 是开放字典，新增一项即可，旧包仍然解析为“没有该文档”。
- 不写 ADR：这是既有设计的实现，不是新的长期决策。

## 存储

`resolution_effects.json` 使用与其它 world 级 sidecar 相同的纪律：

```text
{
  "version": 1,
  "world_id": "<world id>",
  "state": {"applied_version": 0, "applied": []},
}
```

- 信封恰好三个键；`state` 必须通过 `ResolutionEffects.valid()`，上限 64 KiB。
- 保存先写 `resolution_effects.pending.json`，回读逐字节比对后才 rename 覆盖主文档；中途失败不会留下半份效果文档。
- `load_state()` / `save_state()` 都要求合法 `world_id`；缺失文档是合法空效果且**不写盘**；存在但损坏、版本不支持、属于另一个世界或超出上限都拒绝启动。
- 读回后调用 `normalize()` 把整值浮点恢复成整数，保证重开不因 JSON 往返把 `1` 写成 `1.0`。

## 权威接线

### 激活

`execute_resolution()` 只在 `action == "activate"` 且规则命令成功后登记效果，顺序固定：

1. `ResolutionState.activate()` 产出候选并成功写入 `resolutions.json`；
2. `ResolutionEffects.apply()` 在候选决议文档上登记该生效版本；
3. 效果文档写入 `resolution_effects.json`；
4. 两份活文档一起替换。

为什么不能颠倒：`consistent()` 要求效果水位不超过决议的 `rules_version`，未落盘的候选版本会让 `apply()` 返回 `invalid_state`。

失败处理：

- `apply()` 自身拒绝返回 `resolution_effects_<reason>`；
- 效果写盘失败返回 `save_resolution_effects_<kind>`。

两种情况都**不**回滚已落盘的决议：规则在这条命令里已经合法生效，把 `resolutions` 退回未生效会让内存与磁盘分叉。此时内存与磁盘一致，效果缺口由下次打开世界按水位补齐。

### 重启补齐

打开世界时，在加载效果文档并确认与决议一致之后：

1. 按 `effective_version` 升序遍历 `resolutions.resolutions`；
2. 对 `status == effective`、`effective_version > applied_version` 且 `now >= effective_utc` 的行调用 `apply()`；
3. 遇到“低版本仍未到 `effective_utc`”立即停止，不跳过：水位是全局的，先补高版本会让低版本被判为已应用，那条决议将永久失去效果；
4. 已撤销行跳过且不推进水位（它可能从未生效过）；
5. 有变化才写盘；写盘失败按 `backfill_resolution_effects_<kind>` 拒绝启动，让下一次启动重试。

补齐只发生在打开世界，不在结算或 tick 路径，因此不会在运行中静默改写效果文档。

### 视图

`resolutions_view()` 新增顶层 `effects`，不进每行：

```text
"effects": {
  "applied_version": 0,
  "tax_rate_permille": 0,
  "coefficients": {"public_works_expense": 0, "disaster_loss": 0},
}
```

费率与系数都按视图时刻只读推导，没有效果文档时为 0。超限费率仍报告实际值，视图不截断。摘要（`world_projection.gd`）与面板（`Game/ui/resolutions_panel.gd`）未改，UI 展示属后续切片。`WorldHost` 只在“世界未打开”的默认视图里补同一组空效果键，保持客户端解析一致。

## 世界包与迁移

- `world_package.gd`：白名单、`sidecar_limit` / `sidecar_version` 各加 `resolution_effects.json`；验证器要求恰好三键信封、`ResolutionEffects.valid()` 与包 `world_id` 一致。
- 交叉一致性：`_validate_sidecar_document()` 一次只看一份文档，因此“效果文档必须与同包决议文档一致”放在 `validate_sidecars()` 循环结束之后；两份都在时才检查，缺失由存在性表达。
- `world_transfer.gd`：`BACKUP_FILES` 加 `resolution_effects.json` 与 `resolution_effects.pending.json`，否则导入中途失败无法回滚；`_verify_sidecar()` 用新 store 的回读证明下一批启动会接受该文档。

## 验证

实际运行：

```text
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 300 /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot --headless --path Game --script "$PWD/tests/resolution_effects_authority_test.gd"
```

原始末行：

```text
RESOLUTION_EFFECTS_AUTHORITY_TEST checks=48 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/resolution-effects-authority-533669
RESOLUTION_EFFECTS_TEST checks=100 failures=0
RESOLUTION_STATE_TEST checks=330 failures=0
RESOLUTIONS_STORE_TEST checks=73 failures=0
RESOLUTION_AUTHORITY_TEST checks=125 failures=0
RESOLUTION_NETWORK_TEST checks=48 failures=0
WORLD_PACKAGE_TEST checks=126 failures=0
WORLD_PACKAGE_SIDECARS_TEST checks=79 failures=0
WORLD_TRANSFER_TEST checks=113 failures=0
WORLD_TRANSFER_SIDECARS_TEST checks=152 failures=0
HEADLESS_WORLD_RUNTIME_TEST checks=83 failures=0
CHAIN_CONFLICT_INTEGRATION_TEST checks=512 failures=0
SIDECAR_STORE_GUARDS_TEST checks=246 failures=0
FONT_COVERAGE_TEST checks=1272 failures=0 missing=0
```

覆盖：激活后 sidecar 存在、费率与系数生效；撤销后查询归零且效果文档字节不变；重开不重写；决议已生效但效果缺失时幂等补齐一次、第二次不再写；损坏 / 不支持版本 / 异世界 / 与决议不一致四种拒绝启动；效果保存失败返回具名 `save_resolution_effects_*`、内存与磁盘不分裂、下次打开补齐；新存储的符号链接守卫与其余 13 个 sidecar 存储同组通过。

## 未覆盖

- **跨文件非事务窗口**：`resolutions.json` 与 `resolution_effects.json` 分两次原子替换。若两次之间进程退出，磁盘上会是“决议已生效、效果未登记”；下次打开按水位补齐，但补齐本身再次落盘失败会拒绝启动。没有跨文件事务或预写日志。
- **效果保存失败后的同会话缺口**：规则已落盘且内存也已提交，效果保存失败返回 `save_resolution_effects_*` 但不回滚规则（回滚会让内存与磁盘分叉）。同会话内该决议暂时不计费；下一次成功的激活或打开世界会按水位补齐。由于命令日志先于效果保存写入，同一 `command_id` 的重放仍会返回首次的成功结果——它描述的是规则命令，效果由水位另行收敛。
- **补齐停止语义**：低版本尚未到生效时刻时会停止补齐。若这类行长期存在而高版本先到生效时刻，本次打开不会应用高版本，下一次打开的时钟继续前进后才会补齐。
- **记录淘汰**：效果文档最多 64 条应用记录，淘汰后旧税费决议不再计费，费率可能随文档老化下降；这与 RECORD-14 的既定安排一致。
- **无 UI、无摘要、无真实收入结算**：视图只报告费率与系数，面板与 `world_projection.gd` 未改；`tax_for()` 尚未接入任何未来收入路径。
- **未验证 Windows 实机文件系统与真实多端并发**；保存失败用 pending 路径被目录占用来制造真实失败。
