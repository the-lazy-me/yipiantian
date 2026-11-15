# M9-01 · 本地模型初筛与本机基准（macOS 切片）

- 状态：初筛与本机 smoke 完成（2026-11-15），**M9-01 未验收**
- 前置调查：[本地模型候选与基准协议](../../research/MODEL-CANDIDATES.md)
- 权威规格：[AI 系统](../../06-AI-SYSTEM.md)

## 结论

在 M4 Pro / 24 GB 上，**Qwen3-4B Q4_K_M 作为 M9-02 接入的默认候选**：

- 许可最清晰（Apache-2.0，允许商用、再分发与衍生量化）；
- 官方 GGUF 齐全，本机加载与中文意图 JSON 正常；
- 解码速度约为 Q8_0 的 1.35 倍，权重内存约一半。

Q8_0 保留为质量对照，不作为默认：在本次单样本中没有观察到输出差异，但解码更慢、内存更高。这只是 smoke，不是质量评测。

## 环境

| 项 | 实际值 |
|---|---|
| 硬件 | Apple M4 Pro，24 GB 统一内存 |
| 系统 | macOS 27.0.0（Darwin 27.0.0） |
| 推理后端 | llama.cpp b12400（commit `3e41ae69d`），官方 macOS arm64 预编译包 |
| Metal | 开启，`recommendedMaxWorkingSetSize = 19069.67 MB` |
| 权重来源 | Hugging Face 官方仓库 `Qwen/Qwen3-4B-GGUF`（2026-11-15） |
| 运行方式 | 本机并行有其它构建/测试任务，单次串行请求；数字有资源竞争噪声 |

权重文件：

```text
Qwen3-4B-Q4_K_M.gguf  2497280256 B  sha256 7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5
Qwen3-4B-Q8_0.gguf    4280404704 B  sha256 8c2f07f26af9747e41988551106f149b03eb9b5cb6df636027b6bf6278473300
```

## 实测

`llama-bench -p 512 -n 128 -r 3`（Metal，prompt 处理 / 生成）：

```text
qwen3 4B Q4_K - Medium   2.32 GiB  MTL,BLAS  pp512  579.37 ± 8.31 t/s  tg128  60.83 ± 0.76 t/s
qwen3 4B Q8_0            3.98 GiB  MTL,BLAS  pp512  678.05 ± 1.96 t/s  tg128  45.21 ± 1.85 t/s
```

同一中文意图任务（`temperature 0`、`seed 42`、`n=64`、`/no_think`）：

```text
Q4_K_M  输出 {"intent":"trade","confidence":0.9,"reason":"邻居询问青菜价格并表示购买意图，符合交易场景","state_version":"v1"}
        Prompt 291.5 t/s  Generation 60.0 t/s  墙钟 5.37 s  max RSS 8545648640 B  峰值 footprint 6211459984 B
Q8_0    输出 {"intent":"trade","confidence":0.9,"reason":"邻居询问青菜价格并提出购买，属于交易意图。","state_version":"v1"}
        Prompt 318.7 t/s  Generation 42.9 t/s  墙钟 4.94 s  max RSS 10362716160 B  峰值 footprint 6212296840 B
```

两份输出都能被 JSON 解析、意图命中枚举、带 `state_version`；没有出现 thinking 泄漏。Q8 墙钟更低是因为 prompt 处理更快，但生成更慢。

## 本机判定

- **Q4_K_M**：`tg ≈ 61 t/s`，单轮意图延迟在数秒内（含一次加载）；适合“按需加载 + 单队列”的调度假设。
- **Q8_0**：`tg ≈ 45 t/s`，RSS 比 Q4 高约 2 GB；在 24 GB 与游戏共存时更接近上限。
- 两者 `peak memory footprint` 相同（约 6.2 GB），说明该指标未完整覆盖 Metal 统一内存；内存判断应以 RSS 与后续 Instruments 复核为准。
- 尚未证明“常驻不抢占游戏”：没有测游戏帧时间、GPU 竞争或能耗。

## 未覆盖（不构成 M9-01 验收）

- **Windows 实机**：无设备，未测 CPU/Vulkan/CUDA 路径。
- **完整任务集**：没有落盘并冻结 20 条意图 + 10 条对话，没有质量评分或盲评。
- **MLX 对照**：未安装、未测。
- **更长上下文与并发**：只测 4K 级 prompt，没有 8K 压力或多请求。
- **游戏共存与能耗**：没有与运行中的农场同屏测量帧时间、功耗或热降频。
- **多轮稳定性**：每个配置只做了一次 smoke（`llama-bench` 三次重复只覆盖吞吐），没有 3 次完整任务重复的 median/p95。

## 下一步

1. 把真实 llama.cpp 后端接到 M9-02/03 的协议与调度器（后端接口、超时、卸载），先用假后端测试。
2. 冻结 `bench-v1` 任务集后补 30 条计时与质量对照；再决定是否测试 Q8 或 MiniCPM4.1。
3. 在游戏运行、第二屏全屏时测量三态（游戏单独 / 模型闲置 / 模型推理）帧时间与能耗；Windows 实机另行安排。
