# 仓库基线与历史资料整合

调查日期：2026-11-14。源码基线：[f816a91242d6bb607aeb80f1cd2c12507fee66b2](https://github.com/the-lazy-me/yipiantian/commit/f816a91242d6bb607aeb80f1cd2c12507fee66b2)。本页是该时点调查快照；后续实时事实仍以配置、代码和项目上下文为准。

## 现场与权限

目标仓库为 `the-lazy-me/yipiantian`，GitHub 元数据确认上游为 `henjicc/yipiantian`，本次账户对目标仓库有 ADMIN 权限。工作使用独立克隆，当前分支 `main`，上游 `origin/main` 指向用户指定 fork；修改前无已有工作区改动，安全同步后与上游一致。原 `rules/project-context.md` 中 henjicc 远端记录属于上游历史环境，不能据此把本次文档推送到原作者仓库。

已阅读根 AGENTS、初始化状态 `ready`、Git、研究、架构、产品范围、模拟、平台、界面、安全、可观测性、测试与规则维护细则；未发现更深层 AGENTS。调查时 `docs/2.0/` 不存在，本轮建立新目录，保留既有设计和历史资料。

本地文档检出未下载 LFS 二进制实体；可读取文本和资产记录，不据此声称完成模型视觉检查、LFS 对象完整性或干净游戏构建。已有 Windows 历史测试只作为带环境的既有证据，本轮没有启动游戏、生成资产、运行性能原型或发布程序。

## 已核对工程事实

| 事实 | 权威来源 | 2.0 处理 |
|---|---|---|
| 引擎锁定 4.7.2-stable | [版本文件](../../../.godot-version) | 保留；引擎升级另立任务 |
| 工程版本 0.1.8，Windows Demo 发布有历史记录 | [工程](../../../Game/project.godot)、[项目上下文](../../../rules/project-context.md) | 不将策划文档提交称为 2.0 游戏发布 |
| 导出配置只有 Windows Desktop；文件/产品版本字段仍显示 0.1.7.0 | [导出设置](../../../Game/export_presets.cfg) | 原样保留；M1/M13 发布审计核对版本字段，不顺手修代码 |
| 存档 VERSION=27，默认 farm-v27，包含主件/备份/临时件 | [FarmStore](../../../Game/farm/farm_store.gd) | v27 一次性迁移是目标，当前读取拒绝其他版本 |
| 农耕权威状态已部分隔离 | [FarmState](../../../Game/farm/farm_state.gd) | 沿现有边界演进，不从零重写 |
| 主场景组合 UI、平台、状态与呈现 | [main.gd](../../../Game/scenes/main.gd) | 按完整调用链渐进提取 |
| C++/Win32 桌面组件与 Godot 平台桥接已存在 | [宿主](../../../native/desktop/README.md)、[桥接](../../../Game/platform/desktop_wallpaper.gd) | Windows 能力不等同 macOS 可用 |
| 已有低占用、停绘制及缓存释放记录 | [项目上下文](../../../rules/project-context.md) | RTX4090 短测不推广至 Mac/核显/长期能耗 |
| 林婶、许伯、阿舟及本地故事已有入口 | [邻居目录](../../../Game/farm/neighbor_catalog.gd)、[故事](../../../Game/farm/neighbor_stories.gd) | 不声称已有大模型自治社会 |
| 有定向 GDScript 测试与 Windows 发布工作流 | [tests](../../../tests/)、[工作流](../../../.github/workflows/release-windows.yml) | 双平台和无头测试是后续目标 |
| 美术源、正式资源与生成记录已有组织 | [资产流程](../../asset-workflow.md)、[ArtSource](../../../ArtSource/) | 复用现有链路和固定风格 |

## 历史与新目标的对应

[design-baseline 入口](../../design-baseline/README.md)已说明早期两作物、旧输入与迁移要求为历史；不能用早期 gameplay.md 的 v3 叙述覆盖当前 v27。视觉 A 工笔淡彩全景与 A 青菜继续生效，B/C 保留历史。2.0 农业生态和经济是新增目标，不把旧资料中的候选列表当作已实现。

旧规则限制当前 Demo 的跨平台、联网和旧存档兼容。本次用户明确要求规划这些能力，故新目录定义其目标与阶段，而旧工程继续按当前规则运行。实际进入 M0/M1/M4 时同步受影响规则的适用范围，不删除历史规范，不以新规划暗示已实现。

前序讨论的 P0 与 M0–M13 编号、五阶段成果和无任务理念已核对并沿用；聊天里的性能、许可和版本说法均以本轮工程与官方来源复核。策划中新增的具体机制写为目标或候选，无虚构验证结论。

## 本轮文档验证范围

检查新增目录覆盖需求、Markdown 相对链接、文件存在、阶段编号与引用、状态措辞、历史版本边界、财产与 AI 权限一致性，以及提交差异仅限策划和必要路由。运行结果由实际交付记录说明；原型仍见[未执行登记](../feasibility/P0-FEASIBILITY.md)。
