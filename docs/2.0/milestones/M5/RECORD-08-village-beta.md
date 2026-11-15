# M5-05 · 熟人村落体验集成证据（fixture）

执行日期：2026-11-15。状态：**本机 fixture 证据完成，不表示 M5-05 或 M5 验收完成**。已在 [M5 PLAN](PLAN.md) 的 M5-05 下链接。

## 范围

新增 `tests/village_beta_test.gd`（`extends SceneTree`，116 项计数断言），在一个权威、两个成员、真实回环 WSS 会话上串联验证 M5-05 的村落主循环：

- 权威复用仓库现有部署入口 `Game/world/world_server.gd`（与 `tests/m4_reconnect_test.gd` 相同，未新造服务器路径）；自签证书、邀请文件、世界目录全部位于每次运行唯一的 `.local/verification/village-beta-<usec>/` 下，成功运行后删除。
- 成员 A（阿青，`player_…41`）与成员 B（小满，`player_…42`）各为独立进程，因为一个 `SceneTree` 只有一个 `SceneMultiplayer`，而两者必须在权威重启前后同时在线。
- 父进程通过编号 step/result 文件编排；成员用 `WorldClient` 接入，因此重连走的是产品自身的退避与 `reconnected`/`state_ready` 路径，而不是测试自造的重连。

## 命令与结果

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 240 "$GODOT" --headless --path Game \
  --script "$PWD/tests/village_beta_test.gd"
```

连续两次运行（同一最终文件，引擎 `4.7.2.stable.official.ed1daf0bf`；其中后两次为切片作者以外的复核运行）：

```text
VILLAGE_BETA_TEST checks=116 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/village-beta-236614
VILLAGE_BETA_TEST checks=116 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/village-beta-224369
```

墙钟耗时：复核两次分别为 4.71 s 与 4.39 s（切片作者原两次为 4.398 s、4.409 s），均远低于 170 s 预算。这四次结果一致；后续压力复现出夹具自身的偶发空读，见下节。`dir=` 每次不同，成功运行后目录已清理。

### 夹具自身的偶发失败与修复

首次登记 CI（run `43673304744`）macOS 失败、Windows 通过：`FAIL B's reconnect reports the persisted sequence`。本机 8 连跑复现两次（一次 9 项失败、一次 `A's reconnect ... (-1 vs 7)`），失败都表现为成员状态文件读到空字典。

根因在夹具而非产品：父进程写入 step/result 文件用的是 `remove` + `rename`，读进程偶尔落在两步之间读到“文件不存在”。修复（提交 `1886cd0`）记录已成功读过的路径，之后读到空内容时在 50 ms 内重试；从未读到的路径仍立即返回空，避免把“权威尚未写入”误当成间隙而拖慢或掩盖真实失败。修复后本机 15 连跑全部 `checks=116 failures=0`。

两平台 CI 证据（run `43673906005`，提交 `1886cd0`）：

```text
rules (macos-latest)    success
rules (windows-latest)  success
```

CI 使用干净检出与 LFS 指针，`village_beta_test` 只依赖无头权威与成员进程，不受无美术环境限制。仍未覆盖双平台真实互访：CI 的两个 job 各自独立运行同一 fixture，不构成 Windows↔macOS 会话。

## 每段证明什么

| 阶段 | 实际观察 | 结果 |
|---|---|---|
| 加入与名册 | 权威以 `world_server.gd` 在回环 WSS 上启动；A、B 用不同玩家 ID 加入同一 `world-village`；双方 summary 就绪；双方名册都有两行且 ID 不同、无重复 | 通过 |
| 授权范围 | A 在两块自己的地里播种；B 无授权收获 A 的 `field_04` 得到权威 `theft_disabled`，回执带 `authorized=false`、完整执行外壳（`stage`/`duplicate`）且序号不前进 | 通过 |
| 签发/撤销 | A 签发 `harvest`+`field_04`，签发者视图出现一条 `out` 授权；再签发 `field_05` 后撤销，A 视图回到一条，B 视图只剩 `field_04`，被撤销地块不再出现 | 通过 |
| 授权生效 | B 在 `field_04` 收获成功，回执带 `authorized=true`、`reward_amount=1`，一篮进入 B 自己的口袋；在已撤销的 `field_05` 仍被权威拒绝 | 通过 |
| 并发建造 | 两个成员在同一 gate 释放后同时提交 `yard_a`/`cottage`；只有一人成功，世界只存一条建筑记录，房主为胜者，蓝图与 600 秒工期正确；败者随后以新序号重试得到 `occupied`，序号与记录都不增加 | 通过 |
| 赠送与幂等 | A 收获一份、送出 1 篮给 B；同 id 重放返回 `duplicate=true`，序号不前进、不再转移；B 拉取新 summary 后，恢复出的口袋非零项恰为 `{greens:1}`（此前 B 已把授权收获的那篮还回 A，避免混淆） | 通过 |
| 干净停机与重启 | 写 stop 标记后权威进程退出，`server-status.json` 为 `stopped`/`saved`；同一端口、同一数据目录重启后加载同一世界；两名成员都在客户端退避窗口内自动重连，各自收到新的权威 summary，重连序号等于持久化序号 | 通过 |
| 重启后状态 | 住宅仍在同一槽位，房主、蓝图、起止时间与施工中状态不变；B 口袋仍恰为 1 份 `greens`，A 口袋不变；A/B 的授权与撤销视图、两行邻里名册都与停机前逐项相同；权威没有自行增长事件 | 通过 |
| 低打扰与普通可用 | B 的 summary 交付次数 ≤12、单份 ≤256 KiB、cell 映射 ≤160 项、不含 `events`/`history`/`tail`；收到的 change 数不超过已提交命令数且每条都是命令而非逐格消息；B 未触发 refused/lost，只做过 `state` 社交读取，从未 `set_theft`，权威世界 theft 表为空，并且完成了加载、查看与重连 | 通过 |

## 未覆盖的 M5-05 验收内容

以下都是本 fixture **没有**证明的，不能据此外推：

- **两平台连续互访未验证**：本证据只在同一台 macOS 上跑一个权威 + 两个本机成员进程，回环 WSS；没有 Windows↔macOS、真实局域网、NAT/防火墙、跨机证书固定或服务器迁移。
- **不是人工双平台试玩**：这是 headless fixture 证据，不是两名真实玩家在两台机器上的连续试玩；不能替代 M5-05 的人工验收。
- **没有 UI/场景/三维画面**：全程 `--headless`，不加载主场景、住宅三维呈现、HUD、社交/建造面板，也不验证视觉风格与接地。
- **“只观看”的完整体验未验证**：只验证了普通成员可加载、查看、重连与完成常规操作；没有长时间在线、真实玩家主观打扰程度或通知/未读摘要的 UX。
- **“不加入组织”是空条件**：产品当前没有组织系统；fixture 只能证明 B 除 `state` 外不需要任何额外社交动作，不能证明未来组织功能的可达性。
- **授权机制只覆盖 owner-consent 路径**：B 是 `member` 角色，拒绝来自权威农场规则的 `theft_disabled`（缺少屋主 `authorized` 授权），而不是 `visitor` 角色的 `forbidden` 入口；后者由 `tests/m5_grant_test.gd` 覆盖。本 fixture 证明的是协作授权 `authorized` 标记的范围，不是角色权限门。
- **授权边界较窄**：只测 `harvest` 一种命令、两块地块、无过期授权、无撤销与在途命令的竞态；sow/water/weed/till 的授权、限额与过期未覆盖。
- **建造是单次门控竞态**：权威单线程顺序执行，证明的是命令串行化与槽位占用，不是多线程数据竞争；只有一次 race，没有多槽位、多成员或大量并发压力。
- **没有材料账本**：建造只占槽位与工期，不扣材料、不回收；M5-04 记录的材料边界仍未覆盖（M7）。
- **住宅不能移动**：只验证建成与保留，没有迁移、拆除后重建或蓝图/材料预留。
- **重启是干净停机**：用 stop 标记正常退出；没有 SIGKILL、掉电、半写存档或迁移中断。
- **赠送边界有限**：只验证一次成功赠送、同 id 重放与接收方恢复；没有余额不足、非法数量、收件箱满、离线收件或重启后再重放（重放发生在重启前）。
- **成员规模与社交面小**：只有两名成员；没有加入/离开、屏蔽、禁言、留言、邀请、联系人迁移或大量授权压力。
- **权威不是玩家**：A、B 都是成员，权威是独立 headless 服务器；房主同时作为玩家、客户端关闭但服务器继续等场景未覆盖。
- **总结界是数据形状上界**：≤12 次、≤256 KiB、≤160 cell 是 fixture 设定的上界，不等同于“玩家主观上不被打扰”的体验验收。

## 已知产品边界与产物状态

- 未发现产品缺陷；未修改任何产品代码、既有测试、文档、PLAN 或工作流。
- 住宅胜者由竞态决定（A 或 B 均可能），fixture 按实际回执断言，不假定方向；连续两次运行均 `failures=0`。
- 测试世界、证书与邀请均为隔离临时数据，成功运行后清理；不触碰玩家存档或真实数据。

## 关联

- 计划：[M5 PLAN](PLAN.md) M5-05。
- 设计：[社交、自建房间与自建住宅](../../systems/society-housing.md)。
- 前序切片：[RECORD-02 协作授权](RECORD-02-grants.md)、[RECORD-04 玩家口袋与赠送](RECORD-04-gifts.md)、[RECORD-06 住宅首版](RECORD-06-housing.md)、[RECORD-07 住宅三维呈现](RECORD-07-housing-3d.md)。
- 同类真实会话 fixture：`tests/m4_reconnect_test.gd`、`tests/m5_grant_test.gd`、`tests/m5_gift_test.gd`。
