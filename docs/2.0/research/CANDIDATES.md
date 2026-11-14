# 初始开源候选与研究档案

核验日期：2026-11-14。通过官方仓库页面、GitHub API、README/许可入口完成初筛。提交日期仅是当时所取默认分支头的时间，不证明维护健康；十个仓库当时未标为 archived。以下均未完成本项目集成或性能实测。

| 项目档案 | 研究主题 | 当前处理 |
|---|---|---|
| [Godot](godot.md) | 无头服务与 Mac 导出 | 既有引擎，继续采用锁定 4.7.2；本次候选快照不代表升级 |
| [Lively Wallpaper](lively.md) | 桌面生命周期、遮挡暂停与多屏 | 参考实现候选，不复制代码 |
| [Luanti](luanti.md) | 自建世界、持久化与区域模拟 | 只借鉴设计，代码复用另评估 |
| [Nakama](nakama.md) | 身份、好友、聊天和权威多人后端 | 直接采用或参考实现候选，尚未选定 |
| [AI Town](ai-town.md) | 居民记忆、对话与共享状态 | 参考实现候选 |
| [llama.cpp](llama-cpp.md) | 跨平台受限推理 | 推理后端候选，待实测 |
| [MLX](mlx.md) | Apple Silicon 端侧推理对照 | Mac 专项候选 |
| [OpenTTD](openttd.md) | 生产、运输、经济与多人规则 | 只借鉴设计 |
| [Freeciv](freeciv.md) | 领土、组织和服务端裁决 | 只借鉴设计 |
| [Unknown Horizons](unknown-horizons.md) | 生产链、库存、贸易与聚落 | 只借鉴设计 |

## 初筛的取舍

Godot 是已有引擎，不重新进行引擎大选。Lively 仅帮助研究 Windows 生命周期；Luanti/Freeciv/OpenTTD/Unknown Horizons 主要提供机制与世界维护经验。Nakama 需证明相对轻量自建服务的收益。llama.cpp 与 MLX 用同任务对照，AI Town 用于研究居民组织方式。

前序讨论还出现过其他较新或许可变化的项目；本轮不把未重新核验的名字写成推荐依赖。需要扩大候选时先记录真实问题，再按方法补证。现有十项已覆盖前期关键风险和后期机制研究入口。

返回[研究方法](../10-OPEN-SOURCE-RESEARCH.md)或[总索引](../00-INDEX.md)。
