# RECORD-13 · 居民只读视图接入世界权威

状态：切片完成，未验收；只表示 M10-04 的只读视图与网络读取部分，不表示
M10-04 或 M10 已完成。
日期：2026-11-16。

## 问题

[RECORD-12](RECORD-12-resident-authority-social.md) 已把居民社交与记忆接入
`HeadlessWorld` 与 `residents.json`，但权威没有把居民状态投影给连接：客户端
只能看到自己的世界摘要，无法知道三名居民的公开关系、记忆规模与真实购买。
本切片新增 `HeadlessWorld.residents_view(viewer)` 与 RPC 25/26，解决：

- 居民未启用时如何明确返回不可用；
- 启用后按什么顺序、哪些字段投影，哪些事实必须留在权威；
- 访客与匿名连接能否读取；
- 请求与答复如何共用 48 KiB 线上预算和令牌桶；
- 重启后同一份视图是否仍一致。

## 边界

- 新增 `Game/world/headless_world.gd` 中的 `residents_view(viewer)` 与两个
  投影辅助函数，`Game/world/world_host.gd` 中的 RPC 25/26、路由、预算与
  令牌桶，`Game/world/world_member.gd` / `world_client.gd` 中的信号与转发，
  以及 `tests/resident_view_authority_test.gd`、
  `tests/resident_view_network_test.gd` 与本记录。
- 未修改 `Game/scenes/main.gd`、`Game/scenes/farm_hud.gd`、`Game/ui/*`、
  `tests/*panel*`、`.github/`、`PLAN.md`、`rules/`、农场存档格式、经济规则、
  `settle_residents()` 或社交规则。
- 视图是纯读取：不推导新规则、不写文档、不改变结算、不授予权限。

## 视图形状

```text
{
  "available": true,
  "reason": "",
  "viewer": "<connection player id or empty>",
  "residents": [
    {
      "id": "npc_lin_shen",
      "display_name": "林婶",
      "role": "official",                 # NpcRoles.role_of
      "traits": {                          # NpcPersonality 的既有派生结果
        "diligence": 50, "warmth": 70, "suspicion": 30,
        "curiosity": 60, "generosity": 60,
      },
      "relations": [                       # 另外两名居民，按名册顺序
        {"id": "npc_xu_bo", "display_name": "许伯",
         "affinity": 8, "last_utc": 1800052812.0, "acts": 4, "gifts": 1},
        {"id": "npc_a_zhou", "display_name": "阿舟", "...": "..."},
      ],
      "memory_count": 4,                   # 记忆条数
      "last_memory_utc": 1800052812.0,     # 最近记忆时刻
      "intents_consumed": 1,               # 已消费意图数
      "last_purchase": {"good": "rice", "at_utc": 1800052810.0},
    },
  ],
}
```

- 未启用：`{available:false, reason:"disabled", viewer, residents:[]}`。
  未打开世界：`reason:"not_open"`。
- 行顺序固定为 `NpcRoster.IDS`；每名居民恰好两行关系，顺序同样是名册顺序。
- 人格取 `NpcPersonality.traits(npc_id, nature.get_seed())`，不重新派生。
- 记忆只给条数与最近 `at_utc`，不下发 `entries`、`summary` 或任何正文。
- `intents_consumed` 取居民意图账本的条目数。账本只保存已消费意图 id 与
  时刻，不保存商品；`last_purchase` 因此从权威农场里本人 `filled > 0` 的
  买单投影商品与 `created_utc`。订单已归档或没有成交时该字段为 `{}`，不会
  把未成交挂单当成购买。
- 不出现现金、账户、口袋、货物总量、权属、订单所有者、对话或记忆正文。

## 网络：RPC 25/26

- `world_host.gd`：`residents_request`（25）与 `_residents_reply`（26），
  `RESIDENTS_MAX_PAYLOAD = WorldPayload.WIRE_BUDGET_BYTES`（48 KiB）。
- 请求与答复共用命令令牌桶；超预算在 `rpc_id` 之前返回 `payload_too_large`。
  答复编码超出预算时通过 `_reject(..., on_residents_channel=true)` 回一条
  可见拒绝。两者都不会静默丢弃，也不会断开连接。
- 读取对已加入的连接开放，包括成员、访客与匿名成员；本切片没有写动作，
  因此不存在角色或 `read_only` 分支。未知动作返回 `unknown_action`。
- `world_member.gd`：新增 `residents_result` 信号、`request_residents()`、
  RPC 25 stub 与 26 解析。
- `world_client.gd`：`WireMember` 在通道 26 先做 `WorldPayload.decode()`，
  再转发给基类；客户端新增同名信号与 `request_residents()` 转发。
- 拒绝文案新增 `not_open`、`disabled`、`unknown_action` 的中文文本，其余沿用
  通用文案。

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 420 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/resident_view_authority_test.gd"
```

原始末行：

```text
RESIDENT_VIEW_AUTHORITY_TEST checks=145 failures=0
```

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 420 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/resident_view_network_test.gd"
```

原始末行：

```text
RESIDENT_VIEW_NETWORK_TEST checks=234 failures=0
```

回归原始末行：

```text
RESIDENT_AUTHORITY_SOCIAL_TEST checks=136 failures=0
DISPUTE_NETWORK_TEST checks=95 failures=0
```

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 未启用（权威） | 返回 `disabled`、空居民表、回显 viewer；不创建 `residents.json` |
| 启用排序/字段 | 3 行严格按 `NpcRoster.IDS`；每行恰好 9 个字段；显示名、角色、五维人格、两条关系、记忆计数、意图计数齐全 |
| 人格 | 与 `NpcPersonality.traits(npc_id, seed)` 完全一致，5 维都在 0..100 |
| 关系 | 恰好另外两名居民；affinity 在 -100..100；动作数与赠礼数非负；动作数总和等于本人记忆行数 |
| 购买投影 | 真实市场成交后 `intents_consumed=1`；`last_purchase.good` 来自商品目录，时刻等于结算时刻 |
| 隐私 | 递归检查任何层级都没有 cash/accounts/account/owner/bag/goods/summary/entries/intents/gifts_utc/state_version/dialogue；序列化文本不含任何记忆摘要 |
| 只读 | 重复调用逐字节一致；调用前后关系、记忆与意图账本逐字节不变；空 viewer 仍可读 |
| 重启（权威） | 同一时刻重启后启用视图逐字节一致；同刻扫描不再产生动作或购买；三份文档不变 |
| 网络启用 | 真实 `world_server.gd --residents` + WSS 25/26；成员真实开市后三名居民完成购买；排序、字段、人格、关系、购买与隐私同上 |
| 重连 | 同一玩家断开重连后仍能读到同一份视图 |
| 访客 | 访客码加入后可以读取；行与成员一致；可重复读；不丢权威连接 |
| 匿名 | 匿名成员可以读取；viewer 为空；居民行数一致 |
| 超预算 | 50 KiB 请求得到 `payload_too_large` 与中文文案；随后读取仍成功 |
| 限流 | 26 次连发触发 `rate_limited`；等待令牌回填后读取恢复；连接未断 |
| 重启（网络） | 以晚于记忆时刻、早于 300 秒冷却的时钟重启；视图与 `residents.json` 字节不变 |
| 未启用（网络） | 同一目录不带 `--residents` 重启：`available=false`、`reason=disabled`、无居民行、sidecar 字节不变 |

## 未覆盖

- **UI**：没有居民面板、卡片、关系列表或购买历史展示；本切片只到权威视图、
  信号与转发。
- **模型对话**：没有提示词、生成、语音或自由文本；视图不下发记忆正文，也
  不接模型读取。
- **真实赠礼**：赠礼仍只写关系与记忆，不扣现金、不移动货物；视图只显示
  赠礼次数。
- **Windows**：只在 macOS 无头模式与 loopback WSS 上验证，未覆盖 Windows
  路径、文件系统或实机。
- **记忆内容与规则**：没有记忆正文、摘要、检索或排序展示；没有关系衰减、
  传闻、邀约裁决或其他社会行为。
- **购买历史**：`last_purchase` 只给最近一笔已成交买单；订单被 256 行上限
  归档后为空，不提供完整购买流水。
- **多权威并发**：未验证两个权威同时写同一目录或同一玩家在多个连接上的
  读取竞争。

## 关联

- [M10 PLAN](PLAN.md)
- [居民社交与记忆接入世界权威](RECORD-12-resident-authority-social.md)
- [居民采购接入世界权威](RECORD-06-resident-sweep.md)
- [居民自发社交](RECORD-08-social.md)
- [居民角色权限矩阵](RECORD-07-resident-roles.md)
- [纠纷权威接入](../M12/RECORD-17-dispute-authority.md)
