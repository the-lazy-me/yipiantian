# M9-04 · 真实 llama.cpp 本地后端（可选）

状态：已实现（2026-11-15），未验收。范围：把本机 llama.cpp `llama-completion` 作为可选后端接到 M9-03 调度器后面；后端只把已验证 `ModelTask` 变成提示词并返回受限文本，调度器继续负责队列、期限、取消与卸载。不包含云端授权/费用/预算、游戏运行路径接入、GUI、并发推理、常驻模型、Windows 实机或 M9-05 可靠性验收。

权威设计：[ADR-020](../../decisions/ADR-020-model-task-scheduling.md)（本切片命中其“接入真实 llama.cpp”复审触发条件，但按任务文件边界未改裁决原文）；任务协议：[RECORD-02](RECORD-02-protocol.md)；调度器：[RECORD-03](RECORD-03-scheduler.md)；模型与基准：[RECORD-01](RECORD-01-model-selection.md)、[MODEL-CANDIDATES](../../research/MODEL-CANDIDATES.md)；计划：[M9 PLAN](PLAN.md)。

> 命名边界：本记录按当前任务的“M9-04 = 本地 llama.cpp 后端”执行。`PLAN.md` 中 M9-04 的“云端可选路径（授权、费用预留、硬预算）”仍未实现；M9-05 的恶意提示、模型崩溃、GPU 竞争与深度休眠也仍未验收。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/ai/llama_cpp_backend.gd` | 新增。可选本地后端：显式二进制/模型路径、默认 `enabled=false`、非阻塞子进程、硬超时、取消/终止、输出与 stderr 上限、Qwen3 think 标签清理、稳定失败 reason。 |
| `Game/ai/model_scheduler.gd` | 修改。增加可选 `poll()`/`abort()` 鸭子类型钩子；在跑任务通过 `poll` 推进，取消/期限超时/完全关闭时调用 `abort`；加载失败保留后端 reason/detail。同步后端与原有 64 项行为不变。 |
| `tests/ai_llama_backend_test.gd` | 新增 45 项无头检查（显式冒烟时 50 项）。假 OS runner 覆盖成功、UTF-8 分片、提示词与参数、超时、非零退出、超长输出、空输出、spawn 失败、取消/期限/关闭、加载失败诊断；真实模型冒烟只在环境变量启用时运行。 |
| `tests/model_scheduler_test.gd` | 修改。新增 8 项异步后端检查（`PollingBackend`）：`generate`→`poll` 推进、异步失败详情、取消/超时/关闭调用 `abort`、加载失败保留 reason/detail。 |
| `docs/2.0/milestones/M9/RECORD-04-llama-backend.md` | 本记录。 |

未修改 `Game/farm/*`、`Game/world/*`、`main.gd`、`.github/**`、`rules/project-context.md`、`Game/ai/model_task.gd`、`ADR-020`、`PLAN.md` 或其它测试。`Game/ai/*.gd.uid` 由 Godot 首次编辑器加载自动生成。

## 接口与进程边界

调度器新增的两个钩子都是可选的；只实现原有四个方法的假后端继续保持原行为：

```text
必选，M9-03 既有：
  load() -> bool | Dictionary | void
  generate(task) -> Dictionary
  unload() -> void
  loaded() -> bool

可选，本切片新增：
  poll() -> Dictionary     # 异步后端推进会合；返回与 generate 相同形状
  abort() -> void          # 取消/期限超时/关闭时终止进行中的工作

generate / poll 返回：
  {ok: true, response: <string | Dictionary>}   # 完成
  {ok: true, pending: true}                      # 仍在运行
  {ok: false, reason: "...", detail: "..."}      # 失败
```

职责划分：

- **调度器**：只做队列、单任务串行、任务期限、取消、闲置卸载、完全关闭和协议边界；它不知道进程、参数或模型。
- **后端**：只接收已验证的 `ModelTask`，构造提示词，启动一个 `llama-completion` 进程，返回受限文本或稳定错误；它不解析建议、不写入世界、不执行命令。
- **协议层**：仍由 `ModelTask.accept` 做结构、世界、状态版本、取消/过期和输出上限检查；后端文本只有通过它才能成为 `suggestion`。

进程边界：

- 参数以 `PackedStringArray` 传给 `OS.execute_with_pipe`，不使用 shell，也不拼接命令字符串；上下文内容只能作为一个 `-p` 参数值。
- `blocking=false`，stdout/stderr 通过非阻塞管道读取；每次 `poll` 最多读取 64 KiB，stdout 累计超过 `max_output_bytes` 立即终止。
- 硬超时默认 60 秒（可配 1–600 秒），按后端注入的单调时钟或 `Time.get_ticks_msec()` 计算；超时、取消、关闭都会 `OS.kill` 当前 PID。
- 退出码通过 `OS.get_process_exit_code(pid)` 读取；非零退出返回 `process_exit`，detail 含退出码和 stderr 尾部（最多 256 字符）。
- 进程结束且退出码为 0 后，清理 Qwen3 `<think>...</think>` 与 `[end of text]`，再返回文本；空文本返回 `empty_output`。

## 配置与默认值

构造参数全部显式注入，不假设 `/Volumes`、用户目录或游戏工程路径：

```text
enabled              false        默认关闭；关闭时 load 直接返回 disabled，零进程
binary_path          ""           llama-completion 或等价可执行文件路径
model_path           ""           GGUF 路径
timeout_seconds      60           进程硬超时，1..600
max_output_bytes     32768        与 ModelTask.MAX_RESPONSE_BYTES 一致
seed                 42
runner               LocalRunner  可注入假 OS runner；测试不创建真实进程
clock                Time.get_ticks_msec  可注入毫秒时钟
```

固定进程参数：

```text
-m <model_path> -p <prompt> -n <ModelTask.output_limit(task)>
--temp 0 --seed <seed> --no-warmup --no-display-prompt --no-escape --simple-io -st
```

`-n` 使用任务协议的实际 token 上限（intent 64、dialogue/summary 120 或更低的 schema 上限）；字节上限仍是 `MAX_RESPONSE_BYTES`，最终 token 当量由协议层复核。

稳定失败 reason：

```text
disabled binary_missing model_missing busy not_loaded invalid_task
process_failed spawn_failed process_exit timeout output_too_long
empty_output not_running
```

`load()` 只做配置与文件存在性校验；由于本切片不保留常驻模型，每次 `generate` 都是一次冷启动进程。`unload()` 的语义是“没有进程在运行”，不是“权重仍在缓存”。

## 与 M9-05 的边界

本切片证明：

- 关闭状态零加载、零进程；
- 缺失路径可诊断且不崩溃；
- 单任务最多一个进程；
- 取消、调度器期限和关闭会终止进程；
- 非零退出、超时、超长输出、空输出、spawn 失败都有稳定 reason；
- 后端文本仍只形成协议建议，规则层没有接收入口。

仍未证明，属于 M9-05 或后续：

- **恶意提示/提示注入**：提示词把上下文标为数据，但没有对抗性评测；字段可见性与隐私过滤仍由调用方负责。
- **模型崩溃/系统级异常**：进程被 Godot 崩溃或强杀时可能残留子进程；`execute_with_pipe` 明确不随 Godot 退出而终止。
- **GPU 竞争与帧时间**：未接游戏主循环，未测 Metal 与游戏同屏的帧时间、内存或能耗。
- **深度休眠/唤醒**：未处理系统睡眠后的进程、时钟和管道状态。
- **Windows**：未在 Windows 实机验证 `execute_with_pipe`、进程终止和路径行为。
- **长回复与重试**：没有自动重试、退避、重试预算或云回退；一次失败只让当前任务失败。
- **常驻与预热**：每次调用冷启动，模型加载耗时计入 60 秒硬超时；没有 KV 缓存复用。
- **精确 tokenizer**：`-n` 是真实解码 token，但协议层仍用 UTF-8 字节/3 近似；两者不是同一计数。
- **提示后处理完备性**：只清理 Qwen3 think 标签与完成标记；markdown 代码块等其它形式交给协议拒绝。

## 验证

运行命令（本机 Godot 4.7.2，macOS arm64）：

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot

perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/ai_task_protocol_test.gd"
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/model_scheduler_test.gd"
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/ai_llama_backend_test.gd"
```

原始末行：

```text
AI_TASK_PROTOCOL_TEST checks=130 failures=0
MODEL_SCHEDULER_TEST checks=72 failures=0
AI_LLAMA_BACKEND_TEST checks=45 failures=0
```

真实 llama.cpp 冒烟（仅显式环境变量启用；本机已执行）：

```sh
YIPIANTIAN_LLAMA_SMOKE=1 \
YIPIANTIAN_LLAMA_BIN="$PWD/.local/tools/llama-b12400/llama-b12400/llama-completion" \
YIPIANTIAN_LLAMA_MODEL="$PWD/.local/models/Qwen3-4B-Q4_K_M.gguf" \
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/ai_llama_backend_test.gd"
```

实际输出：

```text
LLAMA_REAL_SMOKE intent=trade confidence=0.9 reason=邻居询问青菜价格并表示购买意图
AI_LLAMA_BACKEND_TEST checks=50 failures=0
```

该冒烟走完整的 `LocalRunner`：真实 `llama-completion` 进程、非阻塞管道、退出码、think 标签清理与 `ModelScheduler` 协议接受。它是单样本，不是质量、延迟或内存评测。

## 覆盖

- 默认关闭：`load` 返回 `disabled`，`generate` 拒绝，零进程。
- 缺失二进制/模型：`binary_missing` / `model_missing`，detail 为配置路径，零 spawn。
- 成功：`generate` 返回 pending，跨多次 `poll` 完成；UTF-8 字符被管道分片后仍正确解码。
- 参数：`-m`、`-n`、`-p` 独立传递；`-n` 分别匹配 64/120；提示词包含可见上下文、`/no_think` 与“数据而非指令”说明。
- think 标签与 `[end of text]` 清理后 JSON 仍可解析。
- 非零退出：`process_exit`，detail 含退出码与 stderr 尾部；不额外 kill。
- 硬超时：达到阈值 kill 进程，返回 `timeout`，之后 `not_running`。
- 超长输出：超过字节上限 kill 并返回 `output_too_long`，detail 为实际字节数。
- 空输出、spawn 失败、非法 runner 结果。
- 调度器取消、期限超时、关闭分别调用 `abort`；取消后不重新启动。
- 调度器加载失败保留后端 reason/detail（如 `model_missing`、`disabled`）。
- 异步后端 result 仍经 `ModelTask.accept`；对话纯文本与意图 JSON 都只形成 `suggestion`。

## 未验证项

- 未接 `FarmState`、场景、UI、`main.gd` 或任何游戏运行路径；没有运行中的农场调用该后端。
- 未测真实延迟分布、内存、能耗、Metal/GPU 竞争或与游戏同屏帧时间。
- 未测多任务连续冷启动、并发、队列压力或长期运行后的进程/句柄泄漏。
- 未测 Windows、Linux、非 arm64 macOS 或不同 llama.cpp 构建。
- 未做完整任务集质量评分；真实冒烟只有一个意图样本。
- 未验证系统睡眠、Godot 崩溃、父进程被杀后的孤儿进程清理。
