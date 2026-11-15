# M9-02 · 模型任务协议

状态：已实现（2026-11-15），未验收。范围：三类任务、可见上下文字段、固定意图枚举、状态版本、期限与取消标识、输出与上下文上限，以及把模型响应解析为**建议**。不包含真实模型、推理后端、网络、云调用、UI、存档或世界状态写入。

权威设计：[ADR-020](../../decisions/ADR-020-model-task-scheduling.md)；上层规格：[NPC、商人与混合 AI](../../06-AI-SYSTEM.md)；计划：[M9 PLAN](PLAN.md)；模型与基准前置：[MODEL-CANDIDATES](../../research/MODEL-CANDIDATES.md)；同切片调度记录：[RECORD-03](RECORD-03-scheduler.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/ai/model_task.gd` | 新增。任务创建/结构校验、过期与取消判定、世界与状态版本边界、JSON/纯文本响应解析、建议过滤。纯静态函数，显式注入 `now_utc`，无场景、磁盘、网络或世界写入。 |
| `tests/ai_task_protocol_test.gd` | 新增 130 项无头检查：三种任务往返、全部拒绝路径、跨世界/过期/取消后迟到响应、响应解析与非法意图、输入与输出边界。 |
| `docs/2.0/decisions/ADR-020-model-task-scheduling.md` | 本切片的持久裁决。 |
| `docs/2.0/milestones/M9/RECORD-02-protocol.md` | 本记录。 |

未修改 `Game/farm/*`、`Game/world/*`、`Game/scenes/*`、`Game/ui/*`、`.github/**`、`rules/**`、任何 `PLAN.md`、`decisions/README.md` 或其它测试。`Game/ai/*.gd.uid` 由 Godot 4.7.2 首次加载自动生成。

## 规则与数值

```text
TYPES              intent / dialogue / summary（固定）
INTENTS            greet / trade / work / conflict（对应 MODEL-CANDIDATES 四类）
MAX_CONTEXT_BYTES  8192   JSON.stringify(visible_context) 的 UTF-8 字节上限
MAX_CONTEXT_DEPTH  8      可见上下文嵌套上限
MAX_RESPONSE_BYTES 32768  字符串响应原始字节上限
BYTES_PER_TOKEN    3      token 近似：ceil(UTF-8 bytes / 3)，不是真实 tokenizer
OUTPUT_MAX_TOKENS  intent 64 / dialogue 120 / summary 120
MAX_ID_LENGTH      128
MAX_WORLD_ID_LENGTH 128
MAX_STATE_VERSION_LENGTH 64
MAX_CANCEL_ID_LENGTH 128
MAX_REASON_LENGTH  512
```

任务恰好九个字段：

| 字段 | 规则 |
|---|---|
| `id` | 非空、≤128、无控制字符 |
| `type` | 固定三种之一 |
| `world_id` | 非空、≤128、无控制字符；接受前必须等于当前世界 |
| `state_version` | 非空、≤64、无控制字符；接受前必须等于当前状态版本 |
| `visible_context` | 只允许固定字段白名单；JSON 可序列化；≤8192 字节；≤8 层 |
| `output_schema` | `intent` 为固定枚举内的非空子集；文本类型为 `max_tokens` 1..类型上限 |
| `created_utc` | 可选输入，默认注入的 `now_utc`；不得晚于 `now_utc` |
| `deadline_utc` | 必须晚于 `created_utc`；`now_utc >= deadline_utc` 即过期 |
| `cancel_id` | 可选输入，默认等于 `id`；存入任务后必须存在且合法 |

可见上下文字段白名单：

```text
npc_id npc_name player_id player_name location topic message nearby
inventory prices relationship recent_events memories weather time_utc
```

- 未知键拒绝；值的类型只接受 JSON 兼容数据（`null`、布尔、整数、有限浮点、字符串、数组、字符串键字典），`Object`、`Callable`、非有限浮点和非字符串键拒绝。
- 这层只限制“可见字段名”和序列化形状；字段值是否真的对 NPC 可见仍由调用方负责。

## 接口

```text
ModelTask.create(fields, now_utc) -> {ok, reason, task}
ModelTask.validate_structure(task) -> {ok, reason}
ModelTask.valid(task) -> bool
ModelTask.validate(task, world_id, state_version, now_utc, cancelled_ids) -> {ok, reason}
ModelTask.expired(task, now_utc) -> bool
ModelTask.cancelled(task, cancelled_ids) -> bool
ModelTask.accept(task, world_id, state_version, response, now_utc, cancelled_ids)
    -> {ok, accepted, suggestion, reason}
ModelTask.output_limit(task) -> int
ModelTask.token_estimate(text) -> int
```

边界顺序固定为：结构 → 世界 → 状态版本 → 取消 → 过期。取消优先于过期，因为调用方已经明确撤回任务；同一 `cancel_id` 之后到达的响应返回 `accepted=false, reason="cancelled"`，过期返回 `reason="expired"`。

`cancelled_ids` 接受 id 数组或以 id 为键的字典，便于调度器持有有界取消集合。

## 响应解析

- `intent`：只接受 JSON 对象。必须命中任务 `output_schema.intents`（其本身是固定 `INTENTS` 的子集），必须携带与任务一致的 `state_version`。`confidence` 可选，必须为 0..1 的有限数；`reason` 可选，必须是 ≤512 字符文本。整体建议序列化后必须 ≤ 64 token 当量。
- `dialogue` / `summary`：接受 JSON `{"text": "..."}` 或纯文本。空文本拒绝；token 当量不得超过任务上限（默认 120，可在 schema 内调低）。
- 只有以 `{` 开头的字符串才进入 JSON 解析；普通中文回复不会被当作 JSON 错误。`intent` 的非对象文本按 `invalid_json` 拒绝。
- 响应中的未知键不会进入建议。例如 `{"command":"pay","world_mutation":{...}}` 只保留 `intent/confidence/reason/state_version`。
- 本模块不写入任何世界状态；`suggestion` 只是数据。执行前仍须由规则层重新核对预算、权限、库存、距离、合同与世界版本（[06-AI-SYSTEM](../../06-AI-SYSTEM.md)）。

稳定拒绝原因：

```text
invalid_task invalid_time unknown_field unknown_type invalid_id invalid_world
invalid_state_version invalid_context unknown_context_key context_too_large
invalid_output_schema unknown_intent invalid_output_limit invalid_created
invalid_deadline invalid_cancel_id cross_world state_version_mismatch
cancelled expired invalid_response empty_response response_too_long invalid_json
missing_intent missing_state_version invalid_confidence invalid_reason
output_too_long
```

## 测试

运行命令（本机 Godot 4.7.2）：

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/ai_task_protocol_test.gd"
```

原始末行：

```text
AI_TASK_PROTOCOL_TEST checks=130 failures=0
```

覆盖：

- 三种任务创建往返；默认输出 schema、默认 `cancel_id`、可选 `created_utc`、意图子集与自定义输出上限。
- 未知类型、非法 id/world/state version、缺失/非字典上下文、未知上下文字段、上下文恰好 8192 与 8193 字节、不可序列化值、意图枚举/重复/空集/未知 schema 键、文本上限越界、非法创建时间/期限、过期创建、非法取消标识、未知顶层字段。
- 存储任务缺 `cancel_id`、空 `cancel_id`、未知字段、非字典任务、类型/期限/schema/上下文损坏。
- 跨世界、状态版本不匹配、恰好到期、取消数组/字典集合、取消优先于过期、无效时钟视为过期。
- 三类响应往返；JSON 字符串与对象；未知响应键不进入建议；意图子集限制；缺失/非法意图；缺失/错误 `state_version`；非法 `confidence`/`reason`；空响应、空白响应、非字符串响应、超长响应、超长文本与超长理由。
- 接受前任务字典逐字段不变（模型响应不修改任务/世界）。

## 未覆盖与无法断言

- 未接入真实模型、llama.cpp/MLX、tokenizer、网络或云路径；64/120 token 是 UTF-8 字节近似，不是实际 token 计数。真实模型能否稳定产出合法 JSON/意图、实际长度分布，本轮无法断言。
- 未做 GUI、存档、会话恢复、并发/线程、能耗、Windows 实机、M9-04 云预算或 M9-05 可靠性。
- 8 KiB 上下文与 64/120 输出上限是当前实验边界，是否覆盖未来所有 NPC 场景尚未验证。
- 字段白名单只约束键名；值的可见性、隐私过滤和提示注入防护仍需调用方与 M9-05 处理。
- 未修改 `FarmState` 或游戏运行路径，协议目前是独立可测试切片。
