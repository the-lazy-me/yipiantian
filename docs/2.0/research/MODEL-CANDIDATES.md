# 本地中文小模型候选与 macOS 基准协议（M9-01 前置）

核验日期：2026-11-15。状态：**仅调查，未集成、未实测**；本文不构成选型定案，最终选择由 M9-01 实测与验收决定。

对应 [RIGHTS.md](RIGHTS.md)「模型权重」行与 [M9-01](../milestones/M9/PLAN.md)。本轮只核验官方模型卡、仓库许可与发布页；未下载权重、未安装推理库、未运行任何基准。

## 结论摘要

- **许可最清晰**：Qwen3-4B、Qwen3-8B、MiniCPM4.1-8B 均为 Apache-2.0，允许商用、再分发和衍生量化；需保留许可/版权声明并标注修改。
- **许可可用但有附加条件**：Gemma 3 4B 使用 Gemma Terms of Use（商用允许，再分发需附协议、限制条款和指定 Notice）；Llama 3.2 3B 使用 Llama 3.2 Community License（商用有 700M MAU 门槛，再分发需附协议与 “Built with Llama”）。
- **中文依据强弱**：Qwen3 官方明确列出中文（简体、繁体、粤语）且预训练覆盖 119 种语言；MiniCPM4.1 官方定位中英双语；Gemma 3 仅称 140+ 语言、未单列中文；Llama 3.2 官方支持语言不含中文，**不宜作为中文主力候选，只作对照**。
- **24 GB 适配是估算，不是结论**：4B 的 4-bit/8-bit 与 8B 的 4-bit 有常驻可能；8B 8-bit 接近上限。统一内存与游戏、系统共享，Metal 可用工作集低于 24 GB，必须实测。
- **后端**：llama.cpp 为 MIT、跨平台，适合作为主后端；MLX 核心与 mlx-lm 也是 MIT，但官方 README 只列 macOS Apple Silicon 与 Linux（CUDA/CPU），**未列 Windows**，且它是框架而非完整推理服务，不能作为双平台唯一后端。
- **尚未实测**：没有任何首 token 延迟、tokens/s、峰值内存、冷启动、闲置卸载或游戏帧时间数据。下文协议可直接执行，但本轮未执行。

## 1. 候选模型

### 1.1 模型与运行事实

| 候选 | 发布方 / 发布 | 参数 | 官方可用量化（权重文件） | 原生上下文 | 中文官方说明 | 24 GB 粗估峰值（4K 上下文） |
|---|---|---|---|---|---|---|
| [Qwen3-4B](https://huggingface.co/Qwen/Qwen3-4B) | Qwen Team（阿里），2025-04-29 | 4.0B（非嵌入 3.6B） | 官方 GGUF：Q4_K_M 2.50 GB；Q8_0 4.28 GB | 32,768；YaRN 131,072 | 预训练约 36T tokens，覆盖 119 种语言；Sino-Tibetan 明确列中文（简体、繁体、粤语）、缅甸语 | 4-bit 约 4–5 GB；8-bit 约 5.5–6.5 GB |
| [Qwen3-8B](https://huggingface.co/Qwen/Qwen3-8B) | Qwen Team（阿里），2025-04-29 | 8.2B（非嵌入 6.95B） | 官方 GGUF：Q4_K_M 5.03 GB；Q8_0 8.71 GB | 官方 GGUF 卡写 32,768；Qwen3 博客称 8B 为 128K，口径不一致，待核验；YaRN 131,072 | 同 Qwen3 系列，119 种语言，明确含中文 | 4-bit 约 6–7 GB；8-bit 约 9.5–10.5 GB |
| [Gemma 3 4B IT](https://huggingface.co/google/gemma-3-4b-it) | Google DeepMind，2025-03-12 | 4B | 官方 QAT GGUF：Q4_0 3.16 GB；**无官方 8-bit GGUF** | 128K 输入；8,192 输出 | 训练数据含 140+ 语言；模型卡未单列中文，也未给中文专项评测 | 4-bit 约 4.5–6 GB；8-bit 约 5.5–7 GB（需自行量化） |
| [MiniCPM4.1-8B](https://huggingface.co/openbmb/MiniCPM4.1-8B) | OpenBMB，2025-09-05 | 8B | 官方 GGUF：Q4_K_M 4.97 GB；**仓库仅见 4-bit，8-bit 需自行量化** | 65,536；LongRoPE 131,072 | 模型卡标签为中文、英文；提供中文选择题提示；中英双语定位 | 4-bit 约 6–7 GB；8-bit 约 9–10.5 GB |
| [Llama 3.2 3B Instruct](https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct) | Meta，2024-09（HF 仓库创建 2024-09-18） | 3.21B | **无官方 GGUF**；按参数估算 Q4_K_M 约 2.0 GB、Q8_0 约 3.4 GB | 128K | 官方支持语言为英语、德语、法语、意大利语、葡萄牙语、印地语、西班牙语、泰语；**不含中文**，许可称超出支持语言的使用不在范围内 | 4-bit 约 3.5–4.5 GB；8-bit 约 5–6 GB（估算） |

说明：

- “粗估峰值”= 官方权重文件 + 按公开配置计算的 FP16 KV（4K 上下文）+ 1–2 GB 运行时/缓冲；**未实测**。Gemma 3 4B 的注意力为局部/全局混合，KV 未单独计算，表中给区间；实际以基准采集为准。
- 24 GB 为统一内存，系统、游戏、模型共享；Metal 可用工作集低于物理内存，不能把 24 GB 全部计入模型预算。
- Qwen3-4B/8B 默认开启 thinking；MiniCPM4.1 为 hybrid reasoning。基准必须固定为非 thinking（`enable_thinking=False` 或 `/no_think`），否则首 token 延迟和输出长度不可比。
- 官方文件大小取自 Hugging Face 官方 API `https://huggingface.co/api/models/<repo>?blobs=true`（2026-11-15）及模型卡；十进制 GB。
- Gemma 3 4B 的 3.16 GB 是文本权重；官方 QAT 仓库另含视觉投影 `mmproj` 851 MB，NPC 文本任务不需要加载。
- 表中官方未提供的 8-bit 均指从官方 BF16 用固定版本 `llama-quantize` 生成 Q8_0；这属于衍生量化，按对应模型许可处理。

### 1.2 权重许可

| 候选 | 许可 | 商业使用 | 再分发 | 衍生 / 量化 | 额外条件 |
|---|---|---|---|---|---|
| Qwen3-4B / Qwen3-8B | Apache-2.0 | 允许 | 允许 | 允许 | 保留版权与许可声明；标注修改；如有 NOTICE 需保留；含专利授权条款 |
| Gemma 3 4B IT | Gemma Terms of Use（模型卡字段 `gemma`，2026-04-01 版） | 允许 | 允许，但需满足条件 | 允许修改/衍生；量化未被单独点名，按修改处理 | 再分发须附协议副本；将 §3.2 使用限制写成可执行条款并通知后续用户；修改文件显著标注；非托管分发附指定 Notice 文件；遵守 Gemma Prohibited Use Policy；不得使用 Google 商标；输出不视为衍生模型 |
| MiniCPM4.1-8B | Apache-2.0 | 允许 | 允许 | 允许 | 同 Apache-2.0；模型卡提示使用者自行核验生成内容 |
| Llama 3.2 3B Instruct | Llama 3.2 Community License | 允许，但有条件 | 允许，但需满足条件 | 允许衍生/修改；量化未被单独点名 | 若发布日产品或关联方月活超过 700M，须另行向 Meta 申请；再分发附协议、显著展示 “Built with Llama”、保留指定 Notice；用于训练/改进并分发 AI 模型时名称须以 “Llama” 开头；遵守 Acceptable Use Policy；违约终止后停止使用并删除 |

注意：

- 上表是**条款摘要，不是法律意见**。Gemma Terms 的 Appendix 列的是 “Gemma 3”，未单独列出 4B 变体；正式发行前需按实际权重仓库与条款快照复核。
- Apache-2.0 模型卡与仓库 README 均声明许可；`QwenLM/Qwen3` 仓库根目录 `LICENSE` 本轮返回 404，故以 Hugging Face 模型卡和仓库 README 的 “Apache 2.0” 声明为证据，发行前再核对随权重分发的许可文件。
- 官方 GGUF 仓库通常沿用模型许可；第三方 GGUF 可能引入额外条款或本身构成衍生作品，本轮未核验，不作为候选。
- 本轮未把 Qwen3-4B-Instruct-2507 列入候选：其模型卡为 Apache-2.0、上下文 262,144，但 Qwen 官方组织下未检索到对应 GGUF 仓库（仅见 FP8），第三方 GGUF 未核验。它是后续值得补证的非 thinking 变体。

### 1.3 取舍说明

- **优先进入实测**：Qwen3-4B（许可最清晰、官方 4/8-bit GGUF 齐全、中文依据明确）与 MiniCPM4.1-8B（Apache-2.0、中英双语、官方 Q4）。先做这两个的 smoke，再决定是否扩到 Qwen3-8B。
- **质量/内存权衡组**：Qwen3-8B。4-bit 估算 6–7 GB，8-bit 估算 9.5–10.5 GB；后者在 24 GB 上与游戏共存是否可行必须实测。
- **第二波**：Gemma 3 4B。许可可用，但再分发条件更多、无官方 8-bit GGUF、中文无官方专项说明；先解决量化与许可快照再测。
- **只作对照**：Llama 3.2 3B。许可有额外门槛，官方语言不含中文；其价值是提供“更小参数、较弱中文”的基线，不应作为中文主力。
- 未核验许可的模型、未核验来源的第三方量化不进入候选；不因“可运行”推断“可分发”。

## 2. 推理后端许可与平台

| 后端 | 许可（固定版本） | 平台支持 | 是否可随游戏分发 | 额外条款 / 限制 |
|---|---|---|---|---|
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | MIT，`Copyright (c) 2023-2026 The ggml authors` | macOS Apple Silicon（Metal、ARM NEON、Accelerate）；Windows x64（CPU AVX/AVX2/AVX512、Vulkan、CUDA 等，取决于构建）；Linux 等 | 可以，保留 MIT 版权与许可声明 | 模型权重不在库许可覆盖范围；GGUF 量化文件按模型许可；第三方依赖/系统框架需单独做发行通知；Windows 无 GPU 时走 CPU，性能另测 |
| [MLX](https://github.com/ml-explore/mlx) | MIT，`Copyright © 2023 Apple Inc.` | 官方 README：macOS Apple Silicon（`pip install mlx`）；Linux（CUDA 后端或 CPU-only）；**未列 Windows** | 核心库可以，保留 MIT 声明 | MLX 是数组框架，不是聊天推理服务；实际使用需 [mlx-lm](https://github.com/ml-explore/mlx-lm)（MIT）及 Python 运行时/依赖；发行包体积与依赖许可需另审；不能覆盖 Windows 目标 |
| mlx-lm | MIT，`Copyright © 2023 Apple Inc.` | 随 MLX；目标 Apple Silicon | 可以，保留 MIT 声明 | 依赖 Python、Transformers、Hugging Face Hub 等，需逐项核验；本轮未做完整依赖许可清单 |

结论：

- **llama.cpp 是唯一能同时覆盖 macOS 与 Windows 的候选后端**；MLX 只能作为 macOS 对照。若双后端维护成本高于收益，优先保留 llama.cpp（与 [mlx.md](mlx.md) 的既有判断一致）。
- 候选中的 GGUF 路线（Qwen3、Gemma 3、MiniCPM4.1、Llama 3.2）均计划以 llama.cpp 作为 Windows x64 路径；MiniCPM4.1 的 sparse attention 在固定提交上的支持需先确认。Windows 实际性能本轮未测。
- 两者许可都允许随游戏分发，但“库许可”不等于“模型许可”，也不等于“所有依赖许可”。正式发行需生成第三方通知清单，并固定实际构建/依赖版本。
- 任务描述中的“MLX 仅 macOS”需要修正为：官方当前列 macOS Apple Silicon 与 Linux，未列 Windows；对本项目的 Windows 目标仍不适用。

## 3. macOS 基准协议（未执行）

### 3.1 目标与判定问题

在 **M4 Pro / 24 GB / macOS** 上回答：

1. 同一中文任务集下，各候选 4-bit 与 8-bit 的首 token 延迟、解码速度、峰值内存、冷启动和闲置卸载表现。
2. 模型加载后闲置、以及模型推理时，游戏帧时间是否被显著抢占。
3. 是否存在“可常驻但不抢占游戏”的模型/量化/后端组合；若不存在，是否只能按需加载。

本协议不回答模型质量上限，也不替代 Windows 基准。

### 3.2 固定变量

| 类别 | 固定内容 |
|---|---|
| 硬件 | MacBook Pro M4 Pro，24 GB 统一内存；记录芯片型号、GPU 核心数、macOS 构建号、电源适配器、低电量模式关闭 |
| 热状态 | 每组测试前静置 10 分钟；记录 `pmset -g therm`；必要时用 `powermetrics`（需授权）记录频率/功耗 |
| 显示 | 与游戏交付一致的第二屏 3840×2160 全屏；记录刷新率、缩放、是否外接 |
| 后端 | llama.cpp 固定提交与 CMake 选项（Metal 开/关各一组）；MLX 固定版本、mlx-lm 版本、Python 版本 |
| 权重 | 固定 HF 仓库 + revision + 文件名 + SHA256；不使用“main 最新”作为可复现依据 |
| 提示 | 固定系统提示、任务 JSON、chat template；记录模板哈希；不同模型的模板差异单独记录 |
| 采样 | 分类：temperature 0（greedy）；对话：temperature 0.6、top_p 0.95、top_k 20、min_p 0、presence/repetition penalty 固定并记录 |
| 种子 | 对话固定 seed 42；质量方差另跑 seed 42–46；分类 temp 0 时记录 seed 但不依赖 |
| 输出上限 | 分类 64 tokens；对话 120 tokens；显式设置，避免长输出污染延迟 |
| 上下文 | 主基准 4K；内存压力测试另跑 8K；不默认用最大上下文 |
| 思考模式 | Qwen3、MiniCPM4.1 固定非 thinking；另做一组 thinking-on 仅作成本对照 |
| 并发 | 单请求串行；不并发，不批处理；记录队列与超时 |

### 3.3 中文任务集

**20 条农场 NPC 意图分类**：

- 覆盖 4 类，每类 5 条：社交问候、交易/价格、工作/日程、冲突/传闻。
- 每条输入包含：NPC 身份与可见状态、候选意图列表（固定枚举）、输出 JSON schema、当前世界状态版本。
- 期望输出：`{"intent":"...","confidence":0-1,"reason":"...","state_version":"..."}`；只允许枚举内意图。
- 评分：意图完全匹配率、JSON 解析成功率、schema 合法率、非法意图率、延迟。
- 不使用强制 grammar 作为主基准；主基准暴露格式失败。若后端默认开启约束，记录并关闭，或单独跑一组“约束输出”对照。

**10 条短对话**：

- 4 条农夫–NPC，3 条 NPC–NPC，3 条边界/恶意输入（信息缺失、含糊指代、试图让 NPC 虚构成交或越权）。
- 每条 2–4 轮，固定开场与可见上下文；输出上限 120 tokens。
- 评分（1–5，盲评模型身份）：中文自然度、角色一致性、是否只使用可见信息、是否虚构交易/库存、长度合规；另记事实错误 0/1。
- 不把“对话好听”当作世界事实；交易/付款仍以规则层提交为准。

任务集需版本化（如 `bench-v1`），固定提示文本与期望标签；本轮未编写具体 30 条样本，执行前需落盘并冻结。

### 3.4 运行矩阵

| 后端 | Qwen3-4B | Qwen3-8B | Gemma 3 4B | MiniCPM4.1-8B | Llama 3.2 3B |
|---|---|---|---|---|---|
| llama.cpp（macOS Metal） | Q4_K_M / Q8_0 | Q4_K_M / Q8_0 | 官方 QAT Q4_0 / 自行量化 Q8_0 | 官方 Q4_K_M / 自行量化 Q8_0 | 自行量化 Q4_K_M / Q8_0 |
| MLX（Apple Silicon） | 4-bit / 8-bit | 4-bit / 8-bit | 4-bit / 8-bit（需确认架构支持） | 条件项：先确认 mlx-lm 支持 | 4-bit / 8-bit（需确认架构支持） |

- 先跑 smoke：Qwen3-4B Q4/Q8 + MiniCPM4.1-8B Q4，各 1 次 warmup + 3 次重复；通过后再扩全矩阵。
- 每个模型/量化/后端：30 条任务 × 3 次计时重复；对话质量另跑 5 个 seed；报告 median、p95、min/max。
- 自行量化统一用固定版本工具，记录输入文件、命令、输出 SHA256；不同量化算法（Q4_K_M、Q4_0、MLX 4-bit）不跨格式直接比较，只做同模型/同后端内的 4-bit vs 8-bit 对照。

### 3.5 采集步骤

1. **准备与校验**：下载（经用户授权后）官方权重，记录 revision、文件大小、SHA256；校验 chat template 与 tokenizer；确认模型可在固定后端加载。
2. **冷启动**：结束进程，记录 `t_exec`；从进程启动到首个内容 token 计时。区分“冷进程、文件缓存热”与“重启后冷文件缓存”；后者可选，需授权执行 `purge` 或重启。
3. **预热**：每个模型/量化跑 1 次不计入统计的请求；记录模型加载时间、prompt 处理时间。
4. **计时**：串行发送 30 条任务；流式读取；记录请求发出、首 token、末 token 时间；从后端 timings 读取 prompt/decode 速度。
5. **内存**：请求期间每 50–100 ms 采样 `ps -o rss=`；峰值时执行 `footprint -p <pid>`；记录 `sysctl vm.swapusage` 与 `vm_stat`；Metal 统一内存另用 Instruments（VM Tracker / Metal System Trace）复核。
6. **闲置卸载**：停止请求 60 s；若后端无内置闲置卸载，用外层包装器终止进程/卸载模型；记录 footprint 回落、线程/进程退出、再次加载的首 token。不要假设 llama.cpp 或 MLX 自带闲置卸载。
7. **游戏共存**：按 3.7 的三态测量；游戏保持第二屏前台，采样期间不在主屏操作。
8. **恢复**：清理临时进程与缓存；记录失败、超时、崩溃和重试；不把失败样本计入中位数。

### 3.6 命令示例（占位，执行前按固定版本 `--help` 核对）

llama.cpp：

```sh
# 构建（示例；提交与选项需固定）
cmake -B build -DGGML_METAL=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j

# 量化（自行量化 8-bit 时）
./build/bin/llama-quantize input-bf16.gguf output-Q8_0.gguf Q8_0

# 服务
./build/bin/llama-server \
  -m models/Qwen3-4B-Q4_K_M.gguf \
  -c 4096 -ngl 99 -s 42 \
  --temp 0 --metrics --perf \
  --host 127.0.0.1 --port 9931
```

请求使用 OpenAI 兼容 `/v1/chat/completions`；流式读取首 token；非流式响应读取 `timings.prompt_per_second`、`timings.predicted_per_second`。`seed`、`temperature`、`max_tokens` 的实际传参方式以该固定版本 server 的参数表为准。

MLX：

```sh
# 4-bit / 8-bit 量化
mlx_lm.convert --model Qwen/Qwen3-4B --mlx-path models/qwen3-4b-4bit -q --q-bits 4
mlx_lm.convert --model Qwen/Qwen3-4B --mlx-path models/qwen3-4b-8bit -q --q-bits 8

# 单次生成
mlx_lm.generate --model models/qwen3-4b-4bit \
  --prompt "$PROMPT" --max-tokens 64 --temp 0 --seed 42
```

TTFT 用 `stream_generate` 的流式回调在客户端打点；MLX 的 prompt/decode 速度用同一时间戳计算，不能直接套 llama.cpp 的 timings 字段。

### 3.7 指标定义与游戏共存

| 指标 | 定义 | 采集 |
|---|---|---|
| 首 token 延迟（TTFT） | 请求发出 → 首个内容 token | 客户端流式时间戳 |
| Prompt 处理速度 | 输入 token / 预处理时间 | llama.cpp `timings.prompt_per_second`；MLX 用日志/时间戳 |
| 解码速度 | 输出 token / 首末 token 间隔 | llama.cpp `timings.predicted_per_second`；MLX 计算 |
| 峰值内存 | 进程 footprint 峰值；RSS 作下限；GPU/统一内存另记 | `ps` 采样 + `footprint -p` + Instruments |
| 冷启动 | 进程启动 → 首 token；另记模型加载时间 | 进程/日志时间戳 |
| 闲置卸载 | 闲置触发 → footprint 回落至基线 ±5% 的时间 | 包装器 + `footprint` |
| 游戏帧时间 | p50/p95/p99、1% low、>50 ms / >100 ms 卡顿次数 | Godot 现有性能采样或 Instruments；同一场景/分辨率/存档 |
| 系统压力 | swap 增长、内存压缩、热降频 | `sysctl vm.swapusage`、`vm_stat`、`pmset -g therm`、`powermetrics`（需授权） |

**三态游戏对照**：

- A：游戏单独运行 10 分钟（基线）。
- B：模型加载但闲置 30 分钟（模拟“常驻”）。
- C：模型加载并每 10 秒发 1 个请求，持续 10 分钟（模拟 NPC 间歇推理）。

**建议判定门槛（待与游戏基线锁定，不是实测结论）**：

| 状态 | 通过条件 | 不通过时的含义 |
|---|---|---|
| B 常驻闲置 | 游戏 p99 帧时间增量 ≤ 1 ms；模型平均 CPU < 1%；GPU 无持续工作；无 swap 增长；footprint 在预算内 | 不能“常驻”，只能按需加载 |
| C 推理共存 | 游戏 p99 增量 ≤ 4 ms；无 >50 ms 卡顿；模型 CPU ≤ 2 核；无持续热降频 | 推理只能在游戏暂停/后台运行，或需更小模型/更激进限流 |
| 卸载 | footprint 5 s 内回到基线 ±5%；无残留进程/线程；再次加载 TTFT 可接受 | 存在泄漏或卸载不完整 |

若 B 通过而 C 不通过，结论是“可常驻但推理需让路”；若 B 不通过，结论是“只能懒加载”。两者都不等于“适合常驻”，最终按 M9-03 的调度与预算决定。

### 3.8 4-bit 与 8-bit 对照

- 同模型、同后端、同提示、同种子、同上下文，分别跑 4-bit 与 8-bit；输出上限与采样参数一致。
- 质量差：分类看意图匹配/JSON 合法/非法意图；对话看 5 项评分。若 8-bit 质量提升不足以抵消内存/延迟成本，优先 4-bit。
- 速度差：报告 TTFT、decode tok/s、峰值内存、冷启动；不只报平均 tok/s。
- Gemma 的 QAT Q4_0 与 Q8_0 不是同一量化族；结论只写“该官方 QAT 4-bit 与该自量化 8-bit 的对照”，不泛化为“4-bit 一定如何”。
- MLX 的 4-bit/8-bit 由 `--q-bits` 控制，group size 与量化模式需记录；不要与 GGUF 的 Q4_K_M/Q8_0 直接混比。

## 4. 未实测与未核验

本轮**没有**运行任何模型或基准，**没有**下载权重，**没有**安装 llama.cpp、MLX、mlx-lm 或 Python 依赖。以下均待实测：

- 30 条中文任务上的实际意图准确率、JSON 合法率、对话质量；没有任何模型质量结论。
- M4 Pro 24 GB 上的 TTFT、prompt/decode tok/s、峰值 footprint、冷启动、闲置卸载时间。
- “可常驻但不抢占游戏”的实际判定；3.7 的门槛是建议值，需用游戏基线校准。
- Gemma 3 4B 的中文能力：官方模型卡未单列中文，也无中文专项评测；不能据“140+ 语言”推断中文可用。
- Qwen3-8B 的原生上下文口径：官方 GGUF 卡写 32,768，Qwen3 博客写 128K；需在固定 revision 上核对 config 与实测。
- MiniCPM4.1-8B 的 sparse attention 在 llama.cpp 固定提交上的实际支持与速度；官方卡给 llama.cpp 示例，但本轮未跑通。
- MLX/mlx-lm 对各候选架构（Qwen3、Gemma 3、MiniCPM4.1、Llama 3.2）的逐项支持；本轮未逐模型验证。
- Windows x64 CPU-only / Vulkan / CUDA 路径的性能与可用性；本协议只覆盖 macOS。
- App Store、公证、安装包体积、Python 运行时打包、第三方通知完整性；均未评估。
- 第三方 GGUF 量化的许可与质量；本轮只采用官方仓库或明确标注“自行量化”。
- Gemma Terms 的 4B 变体适用性：Appendix 列 “Gemma 3”，未单列 4B；发行前需按实际仓库与条款快照复核。

## 5. 风险

- **许可与版本变化**：Gemma Terms 当前为 2026-04-01 版，Gemma 4 另有许可；Llama 许可含 700M MAU、命名与 Acceptable Use 条件；发行前必须保存条款快照并复核，不能把本文摘要当作永久授权。
- **量化衍生**：自行量化属于修改/衍生；官方 GGUF 沿用模型许可，第三方 GGUF 可能附带额外条款或来源不明。必须记录量化工具、输入、命令、输出哈希与许可。
- **Windows 无 GPU**：llama.cpp CPU-only 下 8B 8-bit 可能无法满足交互延迟；Windows 的 Vulkan/CUDA 又依赖具体硬件。不能以 macOS Metal 结果推断 Windows。
- **下载体积**：单个模型 4-bit 约 2.5–5 GB、8-bit 约 4.3–8.7 GB；多量化并存会显著增加磁盘与首次下载成本。发行包不应默默携带权重，需玩家明确操作。
- **内存测量偏差**：RSS 不含全部 Metal/统一内存；`footprint` 仍是近似；必须用 Instruments 复核，并同时看 swap/内存压缩与游戏帧时间。
- **热与功耗**：持续推理可能触发热降频；需 AC 电源、静置基线和 30 分钟长测，不能只测短请求。
- **样本量**：20+10 是 smoke 级任务集，不能证明统计意义上的质量优劣；结论只用于筛掉明显不合格组合。
- **比较公平性**：不同模型 chat template、tokenizer、thinking 模式、量化算法不同；必须固定/记录，不能只比字符级 prompt。
- **调度与安全**：模型输出只能作为建议；提示注入、越权、虚构交易等风险不在本文范围，但 M9-02/M9-05 必须覆盖。
- **分发复杂度**：MLX 路线需要 Python 运行时与多层依赖；llama.cpp 路线需处理动态库、Metal/CUDA/Vulkan 构建与第三方通知。两者都要在发行前做实际打包验证。

## 6. 实际打开的官方来源

| 来源 | 链接 | 本轮核验内容 |
|---|---|---|
| Qwen3-4B 模型卡 | https://huggingface.co/Qwen/Qwen3-4B | 参数、32K/131K 上下文、Apache-2.0、100+ 语言 |
| Qwen3-8B 模型卡 | https://huggingface.co/Qwen/Qwen3-8B | 参数、上下文、Apache-2.0 |
| Qwen3-4B 官方 GGUF | https://huggingface.co/Qwen/Qwen3-4B-GGUF | Q4_K_M 2.5 GB、Q8_0 4.28 GB、推荐采样 |
| Qwen3-8B 官方 GGUF | https://huggingface.co/Qwen/Qwen3-8B-GGUF | Q4_K_M 5.03 GB、Q8_0 8.71 GB、上下文口径 |
| Qwen3 发布博客 | https://qwenlm.github.io/blog/qwen3/ | 2025-04-29、36T tokens、119 语言、中文（简/繁/粤）、thinking 开关 |
| Qwen3 技术报告 | https://arxiv.org/abs/2505.09388 | 119 语言；摘要未给训练 token 总量 |
| Qwen3 仓库 README | https://raw.githubusercontent.com/QwenLM/Qwen3/main/README.md | “All our open-weight models are licensed under Apache 2.0” |
| Gemma 3 4B 模型卡 | https://huggingface.co/google/gemma-3-4b-it | 4B、128K 输入/8K 输出、140+ 语言、Gemma 许可 |
| Gemma 3 官方 QAT GGUF | https://huggingface.co/google/gemma-3-4b-it-qat-q4_0-gguf | Q4_0 3.16 GB、QAT、llama.cpp 用法 |
| Gemma 发布博客 | https://blog.google/technology/developers/gemma-3/ | 2025-03-12、1B/4B/12B/27B、128K、35/140+ 语言 |
| Gemma Terms of Use | https://ai.google.dev/gemma/terms | 2026-04-01 版；商用、再分发条件、衍生、Notice、禁用商标 |
| Gemma Prohibited Use Policy | https://ai.google.dev/gemma/prohibited_use_policy | 禁用类别；2024-02-21 版 |
| MiniCPM4.1-8B 模型卡 | https://huggingface.co/openbmb/MiniCPM4.1-8B | 8B、64K/128K、中英双语、Apache-2.0、hybrid reasoning |
| MiniCPM4.1-8B 官方 GGUF | https://huggingface.co/openbmb/MiniCPM4.1-8B-GGUF | Q4_K_M 4.97 GB、llama.cpp 示例 |
| MiniCPM 仓库 LICENSE | https://raw.githubusercontent.com/OpenBMB/MiniCPM/main/LICENSE | Apache License 2.0 |
| Llama 3.2 3B 模型卡 | https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct | 3.21B、128K、官方语言不含中文、llama3.2 许可 |
| Llama 3.2 Community License | https://raw.githubusercontent.com/meta-llama/llama-models/main/models/llama3_2/LICENSE | 商用/再分发/衍生、700M MAU、Built with Llama、命名与终止条款 |
| llama.cpp 固定版本 LICENSE | https://raw.githubusercontent.com/ggml-org/llama.cpp/32bdc3a89e6528d3e419024c833c5dabf32c7541/LICENSE | MIT，ggml authors |
| llama.cpp README | https://raw.githubusercontent.com/ggml-org/llama.cpp/32bdc3a89e6528d3e419024c833c5dabf32c7541/README.md | Apple Silicon/Metal、x86 CPU、CUDA、Vulkan 等后端 |
| llama.cpp server 文档 | https://raw.githubusercontent.com/ggml-org/llama.cpp/32bdc3a89e6528d3e419024c833c5dabf32c7541/tools/server/README.md | `-m/-c/-ngl/-s/--temp/-n/--metrics/--perf`、timings 字段、Windows `llama-server.exe` |
| llama.cpp quantize 文档 | https://raw.githubusercontent.com/ggml-org/llama.cpp/32bdc3a89e6528d3e419024c833c5dabf32c7541/tools/quantize/README.md | `llama-quantize` 用法、Q4_K_M/Q8_0 类型 |
| MLX 固定版本 LICENSE | https://raw.githubusercontent.com/ml-explore/mlx/fc344c986c4169d99f76b5d95ae6b4a58a359a63/LICENSE | MIT，Apple Inc. |
| MLX README | https://raw.githubusercontent.com/ml-explore/mlx/main/README.md | Apple Silicon 框架；macOS + Linux；未列 Windows |
| mlx-lm LICENSE | https://raw.githubusercontent.com/ml-explore/mlx-lm/main/LICENSE | MIT，Apple Inc. |
| mlx-lm README | https://raw.githubusercontent.com/ml-explore/mlx-lm/main/README.md | `mlx_lm.convert -q`、`mlx_lm.generate`、stream_generate、macOS 15+ |
| mlx-lm convert 源码 | https://raw.githubusercontent.com/ml-explore/mlx-lm/main/mlx_lm/convert.py | `--q-bits` 4/8-bit 参数 |
| mlx-lm generate 源码 | https://raw.githubusercontent.com/ml-explore/mlx-lm/main/mlx_lm/generate.py | `--max-tokens/--temp/--top-p/--top-k/--seed/--max-kv-size` |
| Hugging Face 模型 API | `https://huggingface.co/api/models/<repo>?blobs=true` | 官方 GGUF 文件大小与许可标签（2026-11-15） |

未采用为证据：GitHub REST API 本轮返回速率限制；`QwenLM/Qwen3` 根 `LICENSE` 返回 404；HF 上 `meta-llama/Llama-3.2-3B-Instruct` 的 blob 许可页返回 404，改用 Meta 官方 `llama-models` 仓库原始许可文件。以上均未据此推断许可，而是换用已打开的官方入口。
