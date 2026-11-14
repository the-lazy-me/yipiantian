# OpenTTD · 初始研究档案

核验日期：2026-11-14。研究层级：来源与候选初筛；源码关键调用链、兼容性和性能尚待验证。

## 固定来源

- 官方仓库：[OpenTTD/OpenTTD](https://github.com/OpenTTD/OpenTTD)。
- 本轮读取的分支头：[77244c8c99d590a906f7a55bd1e258dee6b08fdf](https://github.com/OpenTTD/OpenTTD/commit/77244c8c99d590a906f7a55bd1e258dee6b08fdf)，提交时间 `2026-11-13T12:30:21Z`。
- 许可入口：[固定版本许可](https://github.com/OpenTTD/OpenTTD/blob/77244c8c99d590a906f7a55bd1e258dee6b08fdf/COPYING.md)；初步结论：GPL-2.0；README 列第三方例外。

README 与 COPYING 说明 GPL v2，第三方模块另有许可。

## 本项目要回答的问题

研究主题：生产、运输、经济与多人规则。研究生产消耗、运输成本和多人确定性结算；提取小型供需实验，检查无限套利与无玩家经济。

不复制以经营竞争为中心的胜利目标；不把运输系统整体移植到田园工程。

## 采用边界与下一步

当前判断：只借鉴设计。对应阶段：M7/M8。先在隔离环境完成最小样例，记录输入、提交、设备/服务依赖、资源结果和失败；再按[研究方法](../10-OPEN-SOURCE-RESEARCH.md)决定采用、借鉴或拒绝。当前没有本项目跑通、能效通过或完整许可审计结论。

许可判断只覆盖已指明的入口，正式复用前核对实际文件、依赖、资源和分发方式。返回[候选清单](CANDIDATES.md)。
