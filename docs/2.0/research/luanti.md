# Luanti · 初始研究档案

核验日期：2026-11-14。研究层级：来源与候选初筛；源码关键调用链、兼容性和性能尚待验证。

## 固定来源

- 官方仓库：[luanti-org/luanti](https://github.com/luanti-org/luanti)。
- 本轮读取的分支头：[a10dc8dbff3b0af8295ae55df44f65b1d9ee92c7](https://github.com/luanti-org/luanti/commit/a10dc8dbff3b0af8295ae55df44f65b1d9ee92c7)，提交时间 `2026-11-09T20:11:20Z`。
- 许可入口：[固定版本许可](https://github.com/luanti-org/luanti/blob/a10dc8dbff3b0af8295ae55df44f65b1d9ee92c7/LICENSE.txt)；初步结论：源码 LGPL-2.1-or-later；媒体包含 CC BY-SA 3.0/4.0 等独立条款。

许可正文分开列出源码、纹理声音与第三方部分，API 的 NOASSERTION 不是无许可。

## 本项目要回答的问题

研究主题：自建世界、持久化与区域模拟。研究服务器时间推进、未加载区域状态、玩家重连和世界备份；用小世界断线恢复检查思路。

借鉴长期世界维护，不迁入体素表现和其整套游戏规则；自托管运维成本要计入。

## 采用边界与下一步

当前判断：只借鉴设计，代码复用另评估。对应阶段：P0-R3、M3/M4。先在隔离环境完成最小样例，记录输入、提交、设备/服务依赖、资源结果和失败；再按[研究方法](../10-OPEN-SOURCE-RESEARCH.md)决定采用、借鉴或拒绝。当前没有本项目跑通、能效通过或完整许可审计结论。

许可判断只覆盖已指明的入口，正式复用前核对实际文件、依赖、资源和分发方式。返回[候选清单](CANDIDATES.md)。
