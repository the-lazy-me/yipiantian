# M5-02 · 协作授权（切片）

执行日期：2026-11-15。状态：协作授权切片完成，不表示 M5-02 或 M5 验收完成；赠送另见 [RECORD-04](RECORD-04-gifts.md)。前置：[M5-01 社交关系模型](RECORD-01-social.md)。

## 实现

M5-01 的权限只有邀请授予的角色（owner/member/visitor），无法表达“访客只能收这一块地的庄稼”。本切片在社交文档里加入协作授权，让房主把具名命令按地块短时交给某个已登记的玩家。

- `Game/social/social_state.gd`（文档版本升到 `version=2`，新增 `grants`）：
  - 一份授权记录 7 个字段：`id`、`from`（签发者）、`to`（被授权者）、`kinds`（命令集合）、`fields`（地块集合，空表示整座农场）、`created`、`expires_at`（`0` 表示不过期）。
  - `GRANT_KINDS = ["sow","water","weed","till","harvest"]`：只覆盖农场命令，身份、社交与搬迁类动作不能被授权。
  - 签发校验：签发者与被授权者都必须是已登记、彼此不同的玩家；命令集合不能为空且必须全部已知；地块集合去重后不超过 32 个；过期时间不得早于当前时间；每人最多 128 条。
  - `allows(state, player, kind, field, now)` 是唯一的判定入口：只匹配 `to`，逐条跳过已过期与地块不符的记录。命令入口每次调用都重新读取文档，因此撤销对**下一条**命令生效，不需要重连或重新拉取状态。
  - `revoke_grant()` 只允许签发者撤销；撤销后再次撤销返回 `missing_grant`。
  - `valid()` 把 `grants` 纳入校验：字段集合精确匹配、id 唯一、双方已登记、命令非空且唯一、地块数上限、时间合法。旧文档（v1）会被拒绝——当前为早期开发阶段，不做存档兼容。
- `Game/world/world_host.gd`：
  - `execute_for_member()` 先看角色：角色不允许时再问 `_grant_allows(peer_id, kind, field_id)`；没有角色（非成员）仍是 `not_a_member`，不被授权绕过。
  - `_grant_allows()` 用**权威世界时钟** `world.now_utc` 判定过期，而不是客户端时间；授权里写了地块时还要求该地块在当前农场真实存在。
  - 社交动作新增 `grant` 与 `revoke`，仍走“副本上执行 → 校验 → 落盘成功 → 才替换权威文档”的路径，授权 id 由宿主随机生成，客户端不能指定。
- 授权随 `social.json` 一起保存、随世界包 v2 一起迁移，没有新增存储格式。

## 验证

`tests/social_state_test.gd`（纯规则，已扩容到 88 项）覆盖签发/撤销/过期/地块范围/非法输入与文档校验；`tests/m5_grant_test.gd` 用一个真实宿主 + 多个真实成员进程跑通线上路径（回环 WSS、自签证书、隔离目录 `.local/verification/m5-grant-*`）。

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 280 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m5_grant_test.gd"
```

结果：`M5_GRANT_TEST checks=34 failures=0`；`SOCIAL_STATE_TEST checks=88 failures=0`。

| 用例 | 断言 | 结果 |
|---|---|---|
| 角色基线 | 访客收获 `field_03` 返回 `forbidden` | 通过 |
| 签发 | 房主签发 `harvest` + `field_03`，签发者视图出现一条 `out` 授权 | 通过 |
| 生效 | 被授权者视图有一条授权；同一地块收获成功且只结算一次（`reward_amount=1`） | 通过 |
| 范围 | 同一授权对 `field_04` 仍返回 `forbidden` | 通过 |
| 撤销 | 签发者撤销成功、视图清空；被授权者**同一会话的下一条**收获立即 `forbidden` | 通过 |
| 过期 | 限时授权到期后，世界时钟越过截止点的下一条收获返回 `forbidden` | 通过 |
| 越权撤销 | 被授权者撤销他人的授权返回 `not_issuer` | 通过 |

用例已加入 `.github/workflows/rule-tests.yml`。

## 未覆盖

- **赠送当时没有实现**：M5-02 的另一半（玩家间原子转移、重复赠送不多发、失败不丢物）在本记录写作时缺少物品归属模型。归属与赠送已在 [RECORD-04](RECORD-04-gifts.md) 按 [ADR-005](../../decisions/ADR-005-player-bags.md) 实现（每玩家口袋 + 一次落盘的转移），但仍未经过 M5-02 的完整验收。
- 授权按玩家 ID 生效，而玩家 ID 仍是客户端自报的声明（见 M5-01 未覆盖），因此授权只能约束“使用这个 ID 的会话”。
- 没有授权变更推送：被授权者要知道自己被授权或撤销，需要重新拉取 `state`。
- 没有 UI：授权面板、地块选择、到期提示都不存在。
- 只测了单机回环与少量进程，没有多房主、长时间运行或大量授权下的限额压力测试。
- 地块存在性校验发生在命令入口；同一命令执行期间地块被移除的竞态未覆盖（当前世界是单线程顺序执行，尚不构成实际窗口）。

## 关联

- 前序：[M5-01 社交关系模型](RECORD-01-social.md)；权限角色：[M4-02 创建与加入](../M4/RECORD-01-join.md)。
- 设计：[社交、自建房间与自建住宅](../../systems/society-housing.md)。
- 阶段计划：[M5 PLAN](PLAN.md) M5-02。
