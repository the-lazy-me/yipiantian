# Unknown Horizons · 初始研究档案

核验日期：2026-11-14。研究层级：来源与候选初筛；源码关键调用链、兼容性和性能尚待验证。

## 固定来源

- 官方仓库：[unknown-horizons/unknown-horizons](https://github.com/unknown-horizons/unknown-horizons)。
- 本轮读取的分支头：[c344bf093df75b1d7a08b2b1306ab2f0664ef54a](https://github.com/unknown-horizons/unknown-horizons/commit/c344bf093df75b1d7a08b2b1306ab2f0664ef54a)，提交时间 `2026-11-11T22:26:11Z`。
- 许可入口：[固定版本许可](https://github.com/unknown-horizons/unknown-horizons/blob/c344bf093df75b1d7a08b2b1306ab2f0664ef54a/doc/licenses/GPL)；初步结论：README 声明 GPL v2；音乐美术声音另在 doc 目录分项。

README 给出 GPL 和媒体许可入口；根 LICENSE 404 不等于无许可。

## 本项目要回答的问题

研究主题：生产链、库存、贸易与聚落。阅读仓储、生产消耗与贸易流程，构造低人口、供给冲击和物流中断实验。

研究机制而非移植引擎；当前框架适配、维护质量和性能均未评估。

## 采用边界与下一步

当前判断：只借鉴设计。对应阶段：M7；P0 建候选。先在隔离环境完成最小样例，记录输入、提交、设备/服务依赖、资源结果和失败；再按[研究方法](../10-OPEN-SOURCE-RESEARCH.md)决定采用、借鉴或拒绝。当前没有本项目跑通、能效通过或完整许可审计结论。

许可判断只覆盖已指明的入口，正式复用前核对实际文件、依赖、资源和分发方式。返回[候选清单](CANDIDATES.md)。
