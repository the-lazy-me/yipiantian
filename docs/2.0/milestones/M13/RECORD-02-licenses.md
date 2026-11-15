# M13-04 · 发行审计：许可与来源（RECORD-02）

日期：2026-11-15。状态：**只读审计完成；发行阻塞项未关闭**。可核验清单见 [LICENSES.md](../../research/LICENSES.md)。

范围：代码、字体、模型/贴图/图标、音频、引擎与导出包内的法律文本，以及 M9 模型与 llama.cpp 的结论复核。不含：签名/公证、隐私合规、Windows 实机、商店提交材料。本轮未改代码、测试、`rules/` 或 workflow，未提交、未推送。

## 结论

1. 引擎与引擎内置第三方组件**可以核验**：`Game/legal/` 两份文件的 SHA-256 与 Godot `4.7.2-stable` 官方 `LICENSE.txt`、`COPYRIGHT.txt` 完全一致。
2. **仓库级许可仍然缺失**（R01 未关闭）：根目录与全部跟踪文件均无 `LICENSE`/`COPYING`，GitHub 两个仓库的 license 接口都是 404。项目代码含 160 个在上游之上的提交，不能因"公开可见 / 可 fork"视为可再分发。
3. 引擎之外唯一有许可正文随包的是**历史 Noto 字体**（`ArtSource/UI/历史字体/OFL.txt`，不随游戏）；现役汇文明朝体只有字体内部 `Copyright: Public Domain` 字段与来源转录，**没有许可正文**。
4. 绝大多数量产美术（Tripo 三维、imagegen 图标）**来源记录齐全、许可依据缺失**：记录能追到任务 ID、提示词、积分，但仓库内没有任何生成服务账户条款或产物权利说明。
5. 模型与推理后端**当前不分发**：仓库无 `.gguf`、无 llama.cpp 二进制，两个导出 PCK 中也不含。相关许可结论可复核（Apache-2.0 / MIT），但尚未准备随包通知。
6. 导出包只携带引擎许可与字体来源转录；**资产通知、字体许可、godot-cpp 通知、项目自身声明都没有进包**，且 macOS 打包链路根本没有复制 `发行材料/来源与通知.txt`。

## 发行阻塞项（按影响排序）

排序依据：影响多少发行内容、是否可绕过、补救成本。

| # | 阻塞项 | 影响面 | 当前证据 | 关闭条件（需用户/授权方提供，不由项目自行补写） |
|---|---|---|---|---|
| B1 | 仓库级许可缺失（R01） | 全部代码 + 派生素材，等于整个发行基础 | 无 `LICENSE`；两仓库 license API 404；`docs/2.0/research/RIGHTS.md` 已记录 | 取得上游作者/权利人的明确授权（修改、商用、再分发、署名范围）或改用权利清晰的新仓库；**不得由项目自行添加 MIT/GPL 声称解决** |
| B2 | Tripo 生成产物的商用与再分发依据缺失 | 约 182 个 GLB 中的绝大多数 + 作物阶段、环境、角色、农具 | 135 份 `task.json`、逐项 README，无条款快照；`tripo3d.ai/terms-of-service` 返回 403，`developers.tripo3d.ai/en/docs/terms` 返回 404 | 按实际账户与生产日期取得 Tripo 产物条款快照（含修改、商用、再分发、署名），存入 `Game/legal/` 或发行材料 |
| B3 | 内置 imagegen 图标的产物权利依据缺失 | UI 图标约 30 张、所有三维资产的输入参考图、远景天空与材质图 | 各 `*-icons.json` / `generation.json` / `image-records.json` 有提示词与返回文件名，无条款 | 取得所用图像服务对应日期的产物权利条款；确认"生成输入提示词 + 馆藏风格参考"不引入第三方权利 |
| B4 | 汇文明朝体许可正文缺失，且字体随包嵌入 | 全部中文 UI；`Game/art/ui/fonts/汇文明朝体.ttf` 在 PCK 内 | `字体来源.txt` 自述"不是新制许可文本…未包含单独许可文件"；字体 name 表 `Public Domain`；猫啃网页面 2026-11-15 未能取回可引用正文 | 取得字体发布方原始授权说明，或经权利人确认 `Public Domain` 声明可作依据；把许可正文随包；否则替换为许可明确的字体（如 Noto OFL 路线，已有正文与记录） |
| B5 | macOS 包没有通知文件，Windows 包通知不含许可正文 | 两个发行目标 | `scripts/package-release.ps1` 复制 `发行材料/来源与通知.txt` 与两份 Godot 文件；`scripts/build-macos.sh`、`.github/workflows/build-macos.yml` 都不复制；`来源与通知.txt` 自身只写"已知来源"，明确不指定许可 | 补齐两平台的通知清单与许可正文；macOS 打包补 `notices/`；macOS 包需单列 godot-cpp MIT 通知（`Game/legal/GODOT_COPYRIGHT.txt` 不含 godot-cpp） |
| B6 | 三类 UI 资源无书面来源记录 | `ui/botanical_corners` 9、`ui/kitchen` 4、`ui/crops/porch-sow` 与 `porch-water` 2 | 前两类可用哈希对应到 `ArtSource` 参考图/服务预览图；`botanical_corners` 只有原始 PNG 与提交 `56ab73a` | 补写记录并用哈希固定对应关系；`botanical_corners` 需回填生成工具、提示词与日期 |
| B7 | 10 份 `ArtSource` README 与 5.1 任务页仍写"商业授权调查暂缓"，与 2026-11-14 起的恢复核验冲突 | 审计可读性，可能被误读为已完成或已放弃 | 检索命中：10 份 README 结论句 + `docs/task/首个可发布版本/…/5.1-…md` | 在文档状态行标注历史口径；不改写历史结论 |
| B8 | 模型权重忽略规则不完整 | 未来误提交风险（当前未发生） | `.gitignore` 只有 `/.local/`；`git check-ignore weights.gguf` 返回未忽略 | 需要时新增 `*.gguf` 忽略或在流程中明确"权重只放 `.local/`"；本轮未改 |

补充的非许可发行问题（记录归档，不列为本轮阻塞）：

- macOS PCK 含 12 条 `development/*`（隐藏模型检查页）与 `macos_desktop.debug.dylib`；`check-release-pack.ps1` 对前者有白名单。
- 本机 macOS PCK 与 dylib 内含 48 处 `/Volumes/Disk-1tb/...` 构建机绝对路径（来自调试符号），Windows 包为 0；属隐私与产物卫生，不是许可问题。
- `制作留档/` 未随当前检出，但 51 个文档引用它；依赖留档的验收复核会断链。

## R01 约束复述（不可越界）

- 本轮**没有**新增、改写或建议任何许可证文本；没有为上游代码或美术指定 MIT/GPL/CC；没有把 `Public Domain` 字段扩写成许可。
- 生成服务条款、字体授权、上游授权只能由用户提供，或由用户明确授权后在对应账户下取得并保存快照。项目侧只做记录、清单与缺口标注。
- 未取得依据的资产在 2.0 发行候选前应排除或替换（M13-04 验收要求原文："许可未明资源不进入发行候选"）。

## 与既有结论的一致性检查

| 既有结论 | 本轮复核 |
|---|---|
| `docs/2.0/research/RIGHTS.md`：无仓库级许可，不授予原作者权利 | 一致；新增 fork 领先上游 160 提交这一事实 |
| `MODEL-CANDIDATES.md` / `M9 RECORD-01`：Qwen3-4B Apache-2.0，llama.cpp MIT | 一致；HF API `apache-2.0`、revision `bc640142…`，仓库含 `LICENSE`、无 `NOTICE`；llama.cpp 固定提交与本机 b12400 都是 MIT `2023-2026 The ggml authors` |
| `M13 RECORD-01`：未签名、未发布、权属未清 | 一致；新增"包内法律文本清单"与"macOS 缺通知"两项事实 |
| `09-QUALITY-GATES.md` Q10：代码、字体、图像、模型、音频和权重来源与用途可核验 | 来源可核验；**用途/分发许可未核验**，Q10 未通过 |

## 未核验项

- 无法在仓库内确认版权的美术：`ui/botanical_corners` 9 张的运行图；`parametric_kit` 的竹材图集与树木贴图逐文件提示词；`ui/camera.svg` 之外未逐项点名的 SVG 的归属（均按项目自制处理，但无独立记录）。
- Tripo 与图像生成服务的条款正文（403/404），以及"按实际生成日期适用的版本"。
- 汇文明朝体的许可正文与再分发条件；字体所基于的"日本旧字体"链条未在本轮核验。
- `Game/legal/GODOT_COPYRIGHT.txt` 是否覆盖导出模板实际链接的全部组件（只核对了哈希一致，未逐项比对模板构建选项）。
- 商店/地区/售价/发行主体：未指定，本轮不适用，未作任何提交结论。
- Windows 实机、签名、公证：属 M13 其它工作包，本文不重复。

## 需要登记到 project-context / decisions 的内容

1. **`rules/project-context.md`**：新增事实"2026-11-15 M13-04 许可审计完成，见 `docs/2.0/milestones/M13/RECORD-02-licenses.md` 与 `docs/2.0/research/LICENSES.md`；R01 未关闭；引擎许可两份文件哈希与官方一致；模型权重与 llama.cpp 未随包"。
2. **`docs/2.0/decisions/RISKS.md` R01**：状态从"开放"改为"开放（已有可核验清单，B1–B8 待关闭）"，关闭证据指向本记录。是否把 B2/B3/B4/B5 拆成独立风险项，需用户决定（本轮未改 RISKS）。
3. **`docs/2.0/research/RIGHTS.md`**：把本轮"代码/资产/字体/法律文本/模型"五类结果并回它的权利清单表，避免两份台账漂移；本轮未改该文件。
4. **历史口径标注**：`docs/task/首个可发布版本/…/5.1-…md` 状态行与 10 份 `ArtSource` README 的"暂缓商业核验"应标为历史，不改结论。

## 复现入口

清单与命令见 [LICENSES.md](../../research/LICENSES.md) 第 7 节；导出包条目解析沿用 [RECORD-01](RECORD-01-export.md) 的 PCK 读取方式（format 4，目录偏移字段）。
