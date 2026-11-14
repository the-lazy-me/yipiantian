# Godot · 初始研究档案

核验日期：2026-11-14。研究层级：来源与候选初筛；源码关键调用链、兼容性和性能尚待验证。

## 固定来源

- 官方仓库：[godotengine/godot](https://github.com/godotengine/godot)。
- 本轮读取的分支头：[960f4db5be16e2f1f7b46f9db7c824c2e0af1035](https://github.com/godotengine/godot/commit/960f4db5be16e2f1f7b46f9db7c824c2e0af1035)，提交时间 `2026-11-13T15:55:49Z`。
- 许可入口：[固定版本许可](https://github.com/godotengine/godot/blob/960f4db5be16e2f1f7b46f9db7c824c2e0af1035/LICENSE.txt)；初步结论：MIT；第三方组件另查。

官方 4.7 文档说明 headless 和专用服务器资源剥离，macOS 导出提供 Universal 2 包。

## 本项目要回答的问题

研究主题：无头服务与 Mac 导出。检查规则入口的传递资源、服务端导出白名单与 Mac 模板；对照完整窗口和无头种收结果。

沿用当前游戏引擎并渐进隔离依赖，避免重写；失败先缩小资源加载边界。

## 采用边界与下一步

当前判断：既有引擎，继续采用锁定 4.7.2；本次候选快照不代表升级。对应阶段：P0-R1/R3、M1/M3。先在隔离环境完成最小样例，记录输入、提交、设备/服务依赖、资源结果和失败；再按[研究方法](../10-OPEN-SOURCE-RESEARCH.md)决定采用、借鉴或拒绝。当前没有本项目跑通、能效通过或完整许可审计结论。

许可判断只覆盖已指明的入口，正式复用前核对实际文件、依赖、资源和分发方式。返回[候选清单](CANDIDATES.md)。
