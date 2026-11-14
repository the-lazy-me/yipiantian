# Lively Wallpaper · 初始研究档案

核验日期：2026-11-14。研究层级：来源与候选初筛；源码关键调用链、兼容性和性能尚待验证。

## 固定来源

- 官方仓库：[lively-community/lively](https://github.com/lively-community/lively)。
- 本轮读取的分支头：[25a0a5f4ed1988ff42117d3a17feb321062237fe](https://github.com/lively-community/lively/commit/25a0a5f4ed1988ff42117d3a17feb321062237fe)，提交时间 `2026-09-29T15:54:12Z`。
- 许可入口：[固定版本许可](https://github.com/lively-community/lively/blob/25a0a5f4ed1988ff42117d3a17feb321062237fe/LICENSE)；初步结论：GitHub 识别 GPL-3.0；采用前核对正文和文件例外。

原 rocksdanister 地址已重定向到 lively-community；项目面向 Windows 动态桌面。

## 本项目要回答的问题

研究主题：桌面生命周期、遮挡暂停与多屏。沿窗口状态通知到暂停/恢复的调用链阅读，比较轮询与事件驱动；试验目标屏遮挡、系统休眠和恢复。

Windows 生命周期经验可借鉴，不能推导 macOS 支持；保留本项目单屏与图标下层规则。

## 采用边界与下一步

当前判断：参考实现候选，不复制代码。对应阶段：P0-R2、M2。先在隔离环境完成最小样例，记录输入、提交、设备/服务依赖、资源结果和失败；再按[研究方法](../10-OPEN-SOURCE-RESEARCH.md)决定采用、借鉴或拒绝。当前没有本项目跑通、能效通过或完整许可审计结论。

许可判断只覆盖已指明的入口，正式复用前核对实际文件、依赖、资源和分发方式。返回[候选清单](CANDIDATES.md)。
