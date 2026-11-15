# M11-03 · 规则决议持久化 sidecar

执行日期：2026-11-16。状态：切片完成，不表示 M11-03 或 M11 验收完成。前置：[M11 PLAN](PLAN.md)、[RECORD-05 · 规则决议](RECORD-05-resolutions.md)、[RECORD-02 · 地籍接入世界权威](RECORD-02-cadastre-authority.md)。

## 问题

RECORD-05 冻结了决议的纯规则命令，但文档只存在于内存：权威进程重启后，提案、表决、生效版本和撤销历史全部丢失。把规则文档塞进 v27 农场存档也不合适：农场 schema 有精确键数契约，而决议是世界级事实，生命周期独立。若每次保存都直接覆盖主文件，崩溃还可能在磁盘上留下半份无法校验的文档，让权威把损坏文档误当成“空决议表”覆盖掉。

本切片只做持久化，**不接权威**：不修改 `headless_world.gd`、`world_host.gd`、RPC、摘要投影或界面，不注册任何命令处理器，也不在重启路径调用本 store。权威接线、命令日志的写入时机与重放语义留给下一片切。

## 边界

- 新增 `Game/world/resolutions_store.gd`、`tests/resolutions_store_test.gd` 与本记录。
- 为满足严格校验与 JSON 往返后的形状一致，在 `Game/world/resolution_state.gd` 补充一个 `normalize(state)` 入口（见下）。`valid()` 已存在且足够，未修改其规则。
- 未修改 `headless_world.gd`、`world_host.gd`、`world_client.gd`、`world_member.gd`、RPC 通道、UI、`PLAN.md`、`.github/`、`rules/` 或其他模块。
- 无 RNG、无系统时钟、无网络、无场景；测试只读写 `.local/verification/`。

## 信封形状

`resolutions.json`（版本 1）：

```text
{
  "version": 1,
  "world_id": "<world id>",
  "state": {"rules_version": 0, "resolutions": {...}},
  "commands": [
    {"command_id": "<id>", "payload": "<json text>", "result": {...}}
  ]
}
```

- 顶层恰好四个键，未知键视为损坏。
- `state` 原样交给 `ResolutionState.valid()` 严格校验；它的形状与 RECORD-05 一致，仍是严格两键文档。
- `commands` 是**有界命令日志**，最多 `MAX_COMMANDS = 64` 行，与 `disputes_store.gd` 的重放窗口一致。每行恰好三键：`command_id` 非空字符串且不超过 128 字符、在日志内唯一；`payload` 为字符串；`result` 为字典。日志不进入 `state`，其内容语义属于未来的权威切片，本层只保证能原样读回。
- 整体受 `MAX_BYTES = 65536` 约束；超限的读取返回 `too_large`，超限的保存同样拒绝。

## 加载与保存语义

`load_state(world_identity)` 返回 `{ok, kind, state, commands}`：

- 路径不安全 -> `unsafe_path`；世界 id 为空或超过 128 字符 -> `invalid_world`。
- 文档缺失 -> `kind = "missing"`，返回 `ResolutionState.empty()` 和空日志；**不写盘**，从未通过决议的世界不会留下 `resolutions.json`。
- 读取失败/非 JSON -> `corrupt`；超过字节预算 -> `too_large`；版本不符 -> `unsupported`；`world_id` 不同 -> `world_mismatch`；`state` 或 `commands` 不合法 -> `corrupt`。
- 成功加载会固定 `world_id`，后续保存写入该身份。加载不重写文件。

`save_state(state, commands = [])`：

- 未成功加载（`world_id` 为空）-> `invalid_world`；`state` 不合法 -> `invalid_state`；日志不合法或超容量 -> `invalid_commands`。
- 与 `territory_store` / `disputes_store` 相同：先写 `resolutions.pending.json`，回读全文比对通过后 `rename` 覆盖主文件，因此崩溃不会留下半份主文档。
- 状态与日志在**同一次原子替换**中写入，重放记录不会比它首次返回的状态活得更久。
- 写入后主文件存在、pending 不存在；第一份保存失败时主文件也不存在。

## `normalize` 补充

JSON 读回会把 `rules_version`、`revision`、`effective_version`、`revoked_version` 变成整值浮点。`valid()` 本来就接受整值浮点，因此不需要改校验规则；但若把这样的文档继续传给纯规则命令，输出形状会与写入前不一致，测试与后续 diff 都难比较。新增的 `ResolutionState.normalize(state)` 在 **`valid()` 通过之后**把这些计数字段恢复为 `int`，时刻字段保持数值；它不做校验，也不修改规则。store 的加载路径调用它，`resolution_state_test.gd` 的 330 项检查保持不变并通过。

## 验证

实际运行：

```text
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 180 /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot --headless --path Game --script "$PWD/tests/resolutions_store_test.gd"
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 180 /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot --headless --path Game --script "$PWD/tests/resolution_state_test.gd"
```

原始末行：

```text
RESOLUTIONS_STORE_TEST checks=73 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/resolutions-store-144316
RESOLUTION_STATE_TEST checks=330 failures=0
```

覆盖：常量与信封键、缺失文档为空且不写盘、空/提案/生效/撤销文档往返、命令日志原样往返、world_id 不符拒绝且不重写、损坏 JSON/缺键/多键/非法 state/超容量日志/未知版本/超字节读取拒绝、超字节保存拒绝、日志重复 id 与未知键/非字符串 payload/非字典 result 拒绝、pending 路径被目录占用时保存失败且主文件字节不变、失败的首存不产生主文档、移除阻塞后重试成功、未加载即保存与相对路径拒绝、加载后整数形状恢复。

## 缺陷与未覆盖

- **权威未接线**：`HeadlessWorld`/`WorldHost` 既不加载也不保存这个 sidecar，RPC、摘要和界面都看不到决议。这是下一片切的范围，不是本切片的能力声明。
- 命令日志的容量淘汰、`command_id` 与请求参数的绑定、重放命中后的返回策略都未实现；本层只按形状和上限存储。未来切片应像 `disputes_store` 一样在追加时淘汰最旧条目。
- 没有并发写入保护。与其他 sidecar 一致，假定世界权威是唯一写者；同一目录被两个权威同时打开不在验证范围。
- 日志 `payload` 的不透明性意味着本层无法判断它是否与 `result` 对应；一致性由上层命令处理器负责。
- 没有迁移逻辑：版本 1 之前不存在该文件，版本号不符直接拒绝启动；早期开发阶段不承诺旧存档兼容。
- 未验证 Windows 实机文件系统行为；`rename` 覆盖只读文件在 macOS 上允许，因此原子性测试用 pending 路径被目录占用来制造真实失败，而不是依赖权限位。

## 关联

- 阶段计划与验收：[M11 PLAN](PLAN.md)（本记录不修改）。
- 纯规则前序：[RECORD-05 · 规则决议](RECORD-05-resolutions.md)。
- 同类 sidecar：[RECORD-02 · 地籍接入世界权威](RECORD-02-cadastre-authority.md)、`disputes_store.gd` 的有界命令日志。
