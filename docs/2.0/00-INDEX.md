# 《我有一片田》2.0 · 长期产品策划与研发行动总索引

版本：2026-11-14 首轮完整规划。当前为 **P0 文档与调查阶段**，技术原型未验收；Windows Demo 0.1.8、Godot 4.7.2 和 v27 仍是现有工程基线。本目录包含可执行设计和行动计划，不是 2.0 已实现功能说明。

## 阅读顺序与权威层级

工程执行先读[根 AGENTS](../../AGENTS.md)、[项目上下文](../../rules/project-context.md)及任务相关规则。产品方向读世界宪章，系统行为读对应规格，实施范围读当前里程碑，验证和选型回到证据与 ADR。不同职责不互相替代。

| 层级 | 权威内容 | 维护边界 |
|---|---|---|
| 工程执行 | AGENTS / rules / 配置 / 当前代码 | 权限、Git、当前事实；本目录不复制全部规则 |
| L1 产品原则 | [01 世界宪章](01-VISION.md) | 无任务自由人生、数据所有权、和平与低打扰 |
| L2 机制与契约 | [02 系统总纲](02-GAME-DESIGN.md)、04–07 与系统分册 | 规则、状态归属、数据、AI、艺术 |
| L3 实施与验收 | [03 路线图](03-ROADMAP.md)、08–09、阶段计划 | 当期范围、工作包、依赖和验收 |
| L4 证据与决定 | 研究、可行性、决策与风险 | 固定来源、实际验证、待测与采用理由 |

产品层的确定目标不自动变成现有代码事实。阶段计划不能改写宪章；具体数值不能在不同计划各维护一份。冲突先确认是历史差异还是有效规范冲突，再更新相应权威页及必要引用。

## 核心文档

| 文件 | 内容 |
|---|---|
| [01-VISION.md](01-VISION.md) | 世界宪章与无任务自由人生 |
| [02-GAME-DESIGN.md](02-GAME-DESIGN.md) | 世界尺度、系统关系、规则与因果 |
| [03-ROADMAP.md](03-ROADMAP.md) | P0、M0–M13、五阶段成果与关键依赖 |
| [04-ARCHITECTURE.md](04-ARCHITECTURE.md) | 单一权威、三模式、深度休眠、低功耗与服务端 |
| [05-DATA-AND-NETWORK.md](05-DATA-AND-NETWORK.md) | 双平台、导出迁移、身份、联系人和自建房 |
| [06-AI-SYSTEM.md](06-AI-SYSTEM.md) | 受限端侧小模型、可选云模型、NPC 与商人 |
| [07-ART-BIBLE.md](07-ART-BIBLE.md) | 固定风格、3D、界面、声音及生成指南 |
| [08-AI-PRODUCTION.md](08-AI-PRODUCTION.md) | 全流程 Vibe Coding 与交付方法 |
| [09-QUALITY-GATES.md](09-QUALITY-GATES.md) | 质量门槛、跨平台、能效、模拟和发行证据 |
| [10-OPEN-SOURCE-RESEARCH.md](10-OPEN-SOURCE-RESEARCH.md) | 开源研究、采用与许可方法 |

## 系统、架构与证据导航

- [自然与农耕](systems/nature.md)：生态、气象、灾害、离线与恢复。
- [经济与金融](systems/economy-finance.md)：动态市场、物流、银行、信用、保险、公共基金。
- [社交与住宅](systems/society-housing.md)：好友、互访、互助、偷菜、自建房间和游戏内建房。
- [政治、冲突与法律](systems/politics-conflict-law.md)：地籍、组织、私兵、有限 PvP、官府执法。
- [平台与能效](architecture/PLATFORM-ENERGY.md)：Windows/macOS 能力与测量方法。
- [基线调查](research/BASELINE.md)、[上游与资产权利](research/RIGHTS.md)、[十项开源候选](research/CANDIDATES.md)。
- [架构决策](decisions/README.md)、[风险登记](decisions/RISKS.md)、[P0 可行性](feasibility/P0-FEASIBILITY.md)。

## 当前行动

从[P0 计划](milestones/P0/PLAN.md)与[首轮工作包](milestones/P0/WORK-PACKAGES.md)进入。首轮先核验许可、v27 映射、Mac 与无头运行，再以配对实测裁决运行形态和推理预算。M0–M13 的独立计划由[路线图](03-ROADMAP.md)统一导航。

本轮已完成的是仓库调查、规划编写与初始来源核验；许可整体核清、Mac/Windows 实机对照、性能、迁移原型和模型试验仍待执行。无实际证据的数字不写成通过结果。

## 状态词与术语

“已实现”必须有代码和对应证据；“已确定”指用户明确的产品要求；“目标设计”是本轮用于研发的方案；“候选/拟议”需比较后决定；“待实测”尚无目标环境运行证据。里程碑“计划中—实现中—待验收—已验收—已发布”分别处理。

世界是持久化规则与状态，房间是访问会话，服务器是权威运行位置；玩家身份跨设备，设备会话可撤销。深度休眠是生命周期状态，不是第四个玩法模式。“自建房间”指自托管多人空间，“自建住宅”指游戏内建筑。

## 与既有资料的关系

[design-baseline](../design-baseline/README.md)的固定风格继续有效，早期玩法及任务交接保留历史。旧 Demo 不承诺全历史兼容；2.0 明确 v27 一次性导入目标及此后的版本化迁移。本文只定义后续工程边界，当前代码和存档未改动。详见[基线差异](research/BASELINE.md)和[ADR-001](decisions/ADR-001-authority.md)。

## 实际文件清单

以下为本轮实际创建的文件，各目录按职责组织；文件列表同时作为完整性检查入口。

- [01-VISION.md](01-VISION.md)
- [02-GAME-DESIGN.md](02-GAME-DESIGN.md)
- [03-ROADMAP.md](03-ROADMAP.md)
- [04-ARCHITECTURE.md](04-ARCHITECTURE.md)
- [05-DATA-AND-NETWORK.md](05-DATA-AND-NETWORK.md)
- [06-AI-SYSTEM.md](06-AI-SYSTEM.md)
- [07-ART-BIBLE.md](07-ART-BIBLE.md)
- [08-AI-PRODUCTION.md](08-AI-PRODUCTION.md)
- [09-QUALITY-GATES.md](09-QUALITY-GATES.md)
- [10-OPEN-SOURCE-RESEARCH.md](10-OPEN-SOURCE-RESEARCH.md)
- [README.md](README.md)
- [architecture/PLATFORM-ENERGY.md](architecture/PLATFORM-ENERGY.md)
- [decisions/ADR-001-authority.md](decisions/ADR-001-authority.md)
- [decisions/ADR-002-runtime.md](decisions/ADR-002-runtime.md)
- [decisions/ADR-003-storage.md](decisions/ADR-003-storage.md)
- [decisions/README.md](decisions/README.md)
- [decisions/RISKS.md](decisions/RISKS.md)
- [feasibility/P0-FEASIBILITY.md](feasibility/P0-FEASIBILITY.md)
- [milestones/README.md](milestones/README.md)
- [milestones/M0/PLAN.md](milestones/M0/PLAN.md)
- [milestones/M1/PLAN.md](milestones/M1/PLAN.md)
- [milestones/M10/PLAN.md](milestones/M10/PLAN.md)
- [milestones/M11/PLAN.md](milestones/M11/PLAN.md)
- [milestones/M12/PLAN.md](milestones/M12/PLAN.md)
- [milestones/M13/PLAN.md](milestones/M13/PLAN.md)
- [milestones/M2/PLAN.md](milestones/M2/PLAN.md)
- [milestones/M3/PLAN.md](milestones/M3/PLAN.md)
- [milestones/M4/PLAN.md](milestones/M4/PLAN.md)
- [milestones/M5/PLAN.md](milestones/M5/PLAN.md)
- [milestones/M6/PLAN.md](milestones/M6/PLAN.md)
- [milestones/M7/PLAN.md](milestones/M7/PLAN.md)
- [milestones/M8/PLAN.md](milestones/M8/PLAN.md)
- [milestones/M9/PLAN.md](milestones/M9/PLAN.md)
- [milestones/P0/PLAN.md](milestones/P0/PLAN.md)
- [milestones/P0/WORK-PACKAGES.md](milestones/P0/WORK-PACKAGES.md)
- [research/BASELINE.md](research/BASELINE.md)
- [research/CANDIDATES.md](research/CANDIDATES.md)
- [research/RIGHTS.md](research/RIGHTS.md)
- [research/ai-town.md](research/ai-town.md)
- [research/freeciv.md](research/freeciv.md)
- [research/godot.md](research/godot.md)
- [research/lively.md](research/lively.md)
- [research/llama-cpp.md](research/llama-cpp.md)
- [research/luanti.md](research/luanti.md)
- [research/mlx.md](research/mlx.md)
- [research/nakama.md](research/nakama.md)
- [research/openttd.md](research/openttd.md)
- [research/unknown-horizons.md](research/unknown-horizons.md)
- [systems/economy-finance.md](systems/economy-finance.md)
- [systems/nature.md](systems/nature.md)
- [systems/politics-conflict-law.md](systems/politics-conflict-law.md)
- [systems/society-housing.md](systems/society-housing.md)
