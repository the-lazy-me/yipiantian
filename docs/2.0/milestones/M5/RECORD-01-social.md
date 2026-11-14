# M5-01 · 社交关系模型（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M5 或 M5-01 验收完成。前置：[M4-03 同步与重连](../M4/RECORD-02-sync.md)。

## 实现

社交数据此前完全不存在：只有三名硬编码邻居 NPC，没有玩家 ID 之间的关系。本切片先建立可验证的纯规则与存储边界，网络接入在其上叠加。

- `Game/social/social_state.gd`：权威世界持有的社交文档。`version=1`，四类内容：
  - `players`：以稳定 Player ID 为键，显示名只是可变标签。重命名不改变身份，也不影响关系。
  - `contacts`：双向联系人；`pending` 记录待答邀请，分 `in`/`out` 两个方向，双方各存一条，因此邀请不会变成收件人无法回答的通知。
  - `blocks`：单向屏蔽。屏蔽会立即解除已存在的关系并清空待答邀请，但**不删除历史留言**——另一方仍可能拥有它。
  - `messages`：公开留言 `to` 为空，只存一份；私人留言只对发件人与收件人可见。已读与删除按查看者记录，一个人删除不会抹掉另一个人的副本。
  - `visits`：最近 128 条访问记录，是有限历史而非审计日志。
- 规则与校验：
  - 邀请不能发给自己；已有联系人不能重复邀请；待答期间不能重复发送；被屏蔽的一方无法发送，屏蔽者也同样不能反向发送。
  - 私人留言要求收发双方都已登记；公开留言只要求发件人合法。消息 id 由权威随机生成并拒绝重复。
  - `valid()` 校验整份文档：版本、字段集合、玩家/联系人/邀请/屏蔽/留言/访问的数量上限、时间范围、Player ID 格式、显示名与文本字符、联系人不得同时出现在屏蔽列表、留言双方必须已登记、已读标记只能为 `true`、消息 id 唯一。
  - 文本不能是纯空白；长度上限 200，显示名 24，屏蔽原因 64。
- `Game/social/social_store.gd`：`social.json` 的持久化。保存前用与加载相同的 `valid()` 校验，写入 `social.pending.json` 后回读比对，再原子替换主文档；目录缺失时创建。主文档损坏返回 `corrupt`，未知版本返回 `unsupported`。
- **在线接入**（第二轮）：
  - 加入请求可带 `player_id` 与 `display_name`。两者都合法才接受；不带 `player_id` 的客户端仍可种田，但社交入口返回 `no_player`，不会拒绝旧客户端。显示名可改，身份不变。
  - 宿主新增社交 RPC（id 7）与回复通道（id 8），动作包括 `state`、`invite`、`accept`、`decline`、`remove`、`block`、`unblock`、`send`、`read`、`delete`、`visit`。请求带 `request_id`，回复按 id 对应；`event` 作为推送使用同一通道。
  - 每个动作都在文档副本上执行规则，只有通过校验并**成功落盘**后才替换权威文档；写盘失败返回 `save_<kind>`，内存不会领先于磁盘。只读状态不重写文件。
  - 私信只推给在线的收件人；公开留言推给除发件人外的所有在线成员；被屏蔽方向在发送前就被拒绝，因此不存在“已推送再过滤”的窗口。
  - 成员侧暴露 `request_social()`、`social`（最近一次视图）以及 `social_result`/`social_event` 信号。
- **随世界迁移**（第三轮）：
  - 世界包格式升到 v2，新增 `social` 键。v1 包仍可读，读取时升级为 v2 并补一份空社交文档；v2 包缺少 `social`、v1 包携带 `social` 都判为 `corrupt`。
  - 导出时从存档目录读取 `social.json` 并写入包；读不出来就中止导出（`social_corrupt`），不会用空文档覆盖联系人与留言。
  - 导入时农场先写入并校验，成功后才写社交文档；写入失败会搬回导入前备份（备份文件集合已包含 `social.json`），不会留下“联系人属于另一个农场”的世界。
  - JSON 读回会把整数变成浮点，社交文档在存储与包中统一走 `canonical()`，同一记录重复保存产生相同字节。

## 验证

`tests/social_state_test.gd`（纯内存，无传输、无场景）：

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 120 "$GODOT" --headless --path Game \
  --script "$PWD/tests/social_state_test.gd"
```

结果：`SOCIAL_STATE_TEST checks=68 failures=0`。

`tests/m5_social_test.gd`：一个真实宿主 + 六个真实成员进程（回环 WSS、自签证书、隔离目录 `.local/verification/m5-social-*`），其中一名成员在另一名发信时保持在线。

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 280 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m5_social_test.gd"
```

结果：`M5_SOCIAL_TEST checks=52 failures=0`；`WORLD_PACKAGE_TEST checks=112 failures=0`、`V27_IMPORTER_TEST checks=68 failures=0`、`WORLD_TRANSFER_TEST checks=75 failures=0` 覆盖包格式升级与迁移。

| 用例 | 断言 | 结果 |
|---|---|---|
| 联系人邀请 | 邀请后双方各有一条待答记录；重复邀请、邀请自己、已联系人再邀请均被具名拒绝 | 通过 |
| 接受/拒绝 | 接受后双向联系人、待答清空；再次接受返回 `no_invitation`；拒绝不留关系 | 通过 |
| 屏蔽 | 屏蔽解除关系、双向拒绝私信、隐藏屏蔽者收件箱中的历史；被屏蔽方仍保有自己的副本；解除后恢复 | 通过 |
| 公开/私人留言 | 公开留言所有玩家可见；私人留言只有收发双方可见；重复 id、纯空白、未登记发件人均被拒 | 通过 |
| 已读/删除 | 已读标记按查看者记录；非参与者不能标记；删除只影响查看者自己的收件箱 | 通过 |
| 访问上限 | 写入超过 128 条后只保留最近 128 条，最旧的先离开 | 通过 |
| 文档校验 | 空文档、未知版本、联系人+屏蔽并存、未登记发件人、非法已读值、重复消息 id、非法方向全部拒绝 | 通过 |
| 存储 | 缺文件时返回空初始状态；保存/重载保留玩家与访问；无效文档被拒；完成后无 pending 残留；损坏文件返回 `corrupt` | 通过 |

在线用例（`M5_SOCIAL_TEST`）：

| 用例 | 断言 | 结果 |
|---|---|---|
| 邀请 | Alice 带稳定 Player ID 加入并邀请 Bob；权威接受，Alice 的视图里有一条 `out` 待答 | 通过 |
| 接受 | Bob 看到同一条为 `in`，接受成功后双方成为联系人 | 通过 |
| 推送 | Bob 发出私信时 Alice 已在线；Alice 恰好收到一条 `message` 事件，带发件人与正文 | 通过 |
| 重连 | Alice 以新会话返回，联系人与私信仍在 | 通过 |
| 屏蔽 | Alice 屏蔽 Bob 后联系人消失、私信从收件箱隐藏；Bob 再发得到 `blocked` | 通过 |
| 恢复 | 解除屏蔽后可重新邀请并接受 | 通过 |
| 匿名 | 不带 Player ID 的成员仍能加入，但社交请求返回 `no_player` | 通过 |
| 非法身份 | 非法 Player ID 在加入阶段被拒，原因 `invalid_player` | 通过 |
| 落盘 | 宿主停止后 `social.json` 仍保有双方联系人、玩家与私信 | 通过 |
| 包内迁移 | 导出把社交文档写入 `world.json`；导入到新目录后双方玩家与联系人仍在 | 通过 |
| 旧包读取 | v1 包解析后升级为 v2 并获得空社交文档；v1 带 social、v2 缺 social 均被拒 | 通过 |

用例已加入 `.github/workflows/rule-tests.yml`。

## 未覆盖

- Player ID 是客户端自报的声明，不是账号验证：同一邀请可以被不同人使用不同 ID 加入，冒充他人 ID 只能靠“谁拿到邀请”这一层约束。把 ID 绑定到邀请条目（一次性授权尤其适合）是下一步。
- 迁移已携带 `social.json`，但只保留社交关系本身；没有独立的“导出个人资料/联系人”流程，也没有跨世界合并策略（两个世界的社交文档不会合并，导入即整体替换）。
- 没有 UI：联系人列表、留言收件箱、屏蔽确认都还没有界面。
- 推送只覆盖留言；联系人邀请/接受、屏蔽等状态变化需要调用方重新拉取 `state`，没有增量事件与未读合并摘要。
- 没有跨设备同步、账号恢复、离线消息队列或消息加密；未测大量玩家下的限额边界。
- 没有“公开内容/私人记录”的导出区分；导出流程仍只处理农场快照。

## 关联

- 设计：[社交、自建房间与自建住宅](../../systems/society-housing.md)；[数据与网络](../../05-DATA-AND-NETWORK.md)。
- 身份与迁移：[M4-04 世界搬迁](../M4/RECORD-03-move.md)、[M4-02 创建与加入](../M4/RECORD-01-join.md)。
- 阶段计划：[M5 PLAN](PLAN.md) M5-01。
