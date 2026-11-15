# M11-01 · 地籍客户端入口：主张与释放（客户端切片）

执行日期：2026-11-15。状态：切片完成，不表示 M11-01 或 M11 验收完成。前置：[M11-02 地籍接入世界权威](RECORD-02-cadastre-authority.md)、[M11-03 地籍可见性](RECORD-03-cadastre-visibility.md)、[ADR-023 · 地籍与建筑归属分离](../../decisions/ADR-023-land-cadastre.md)、[ADR-028 · 建造与地籍权限](../../decisions/ADR-028-build-land-authority.md)。

## 问题

M11-02 已经有权威侧的 `WorldHost.territory_for_member()`，但成员只能通过建造隐式主张土地，无法主动主张一块无主地块，也无法释放自己的地块。M11-03 只补了“看得到归属”，面板没有土地动作。缺的是客户端入口：成员发出意图，权威裁决，所有成员从摘要看到结果。本切片不做转让，因为转让需要选人，留作后续。

## 边界与决定

### 1. 地籍请求走独立 RPC，权威语义不变

- 成员→权威：RPC id 9 `territory_request(payload)`，`payload` 为 JSON 字符串 `{request_id, action, args}`。
- 权威→成员：RPC id 10 `_territory_reply(request_id, payload)`，载荷固定包含 `{ok, action, parcel_id, reason, reason_text, state}`；`state` 是 `territory_view()` 深拷贝。
- 现有 RPC 编号 0–8 不改动；9、10 是此前未使用的新通道。
- 动作与参数原样交给 `territory_for_member()`：操作者仍取连接加入时的 `player_id`，角色门、只读、迁移、未知动作、时间与幂等规则都由既有权威入口裁决。客户端上的 owner、from 或角色都不参与裁决。
- 成员/访客/只读的具名拒绝沿用既有原因：`not_a_member`、`forbidden`、`read_only`、`no_player`、`unknown_action`。失败文案优先用权威返回的 `reason_text`。
- 土地请求与 `submit`、`social_request` 共用命令令牌桶；载荷上限沿用 `MAX_PAYLOAD`，答复与其它权威文档一样经过 48 KiB 线上预算（超限回小型 `payload_too_large`）。
- 成功的主张、释放或转让由权威调用 `_broadcast_summary()`。摘要按收件人投影后携带新的 `territory`，因此其他成员无需本地回放就能看到新归属；客户端不根据答复里的 `state` 改本地归属。

### 2. 客户端只转发，不新增权威

- `WorldMember` 新增 `territory_result(request_id, payload)` 信号、`request_territory(request_id, action, args)` 和 RPC 9/10；未加入时返回 false，不伪发请求。
- `WorldClient` 暴露同名信号和 `request_territory()` 转发；`WireMember` 在基类解析前解码 RPC 10 的线上文档，与 `command_result`、`_social_reply` 使用同一预算解码路径。
- 客户端没有本地归属写入，也没有缓存裁决结果。

### 3. 面板只渲染视图给出的动作

`_parcel_views()` 在既有 `{label, blocked}` 之外增加 `action`：

| 摘要状态 | 视图 `action` | 面板按钮 |
|---|---|---|
| `unclaimed` | `claim`（仅具名成员） | 主张 |
| `claimed` 且 `owner == 本人` | `release`（仅具名成员） | 释放 |
| `claimed` 且他人 | 空 | 不加按钮，保留“不能在别人的地上建房”说明 |
| `public` | 空 | 不加按钮 |
| 缺失地籍/只读/访客 | 空 | 不加按钮，保留原有只读说明 |

`build_panel` 新增 `land_action(slot_id, action)` 信号，只为视图带 `action` 的空槽加 `LandAction_<slot>` 按钮；面板不判断权限，点击只发意图。`main.gd` 用 `TerritoryState.slot_parcel_id()` 反查地块，用 `_new_command_id()` 生成 request_id，调用 `remote.request_territory()`。

### 4. 结果提示与刷新

- 收到 `territory_result` 后刷新宅基面板；失败显示权威 `reason_text`，缺失时走 `_remote_reason()` 的中文兜底。
- 成功不本地改归属：权威随后的摘要广播由 `_on_remote_state()` 触发面板刷新，面板才显示新的“无主/我的/属于某人”。
- 面板打开期间收到任意新摘要时都会刷新，不只是本地提交后。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/world/world_member.gd` | `territory_result` 信号、`request_territory()`、RPC 9/10 |
| `Game/world/world_client.gd` | 同名信号与转发、`WireMember` 解码 RPC 10 |
| `Game/world/world_host.gd` | `territory_request`、`_territory_reply`、答复封装与预算、成功后广播摘要 |
| `Game/ui/build_panel.gd` | `land_action` 信号、主张/释放按钮 |
| `Game/scenes/main.gd` | 视图 `action`、请求发送、结果提示、摘要刷新 |
| `tests/build_panel_test.gd` | 扩展 6 项地籍动作检查 |
| `tests/territory_client_test.gd` | 新增真实 loopback WSS 成员地籍夹具 |
| `docs/2.0/milestones/M11/RECORD-06-cadastre-client.md` | 本记录 |

未改 `Game/world/headless_world.gd`、地籍规则、农场格式（仍 27）、`PROTOCOL_VERSION`（仍 1）。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/territory_client_test.gd"
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/build_panel_test.gd"
perl -e 'alarm shift; exec @ARGV' 400 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_client_scene_test.gd"
perl -e 'alarm shift; exec @ARGV' 400 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_presence_test.gd"
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/territory_authority_test.gd"
```

原始末行：

```text
TERRITORY_CLIENT_TEST checks=30 failures=0
BUILD_PANEL_TEST checks=39 failures=0
M4_CLIENT_SCENE_TEST checks=42 failures=0
M4_PRESENCE_TEST checks=38 failures=0
TERRITORY_AUTHORITY_TEST checks=69 failures=0
```

`territory_client_test.gd` 使用真实 loopback WSS：父进程生成证书与两份邀请，拉起一个权威和 A、B、访客三个成员进程。覆盖：

| 用例 | 检查 |
|---|---|
| 主张 | A 主张无主地块成功；答复带动作与地块；A 的摘要归 A；B 的摘要随广播同样看到 |
| 越权释放 | B 释放 A 的地块被拒 `not_owner`，带中文文案，归属保持 A |
| 释放 | A 释放成功，摘要回到 `unclaimed` |
| 访客 | 访客主张被拒 `forbidden`，地块状态不变 |
| 未知动作 | `graze` 被拒 `unknown_action` |

`build_panel_test.gd` 新增：无主槽出现“主张”、本人槽出现“释放”、他人与公共槽没有按钮、两个按钮分别发出 `(slot_id, action)`；原有 33 项保持通过。

## 未覆盖

- 转让：没有客户端入口，也没有选人界面。协议动作仍可被构造，但本次不提供 UI；转让后的建筑归属、确认与权限交互相应留到后续切片。
- 没有确认对话框：主张/释放点击即发请求，误触只能由权威结果提示。
- 没有本地乐观更新：成功后面板要等下一份摘要才显示新归属；摘要延迟时按钮会短暂保持旧状态。
- 未在 Windows 实机、真实局域网双机或 CI 验证；只在 macOS 本机无头模式跑通。
- 美术与动效未处理：按钮沿用现有主题，没有主张/释放的过渡或地块高亮。
- 没有多成员同时争抢同一地块的面板级竞速测试；权威仍以 `already_claimed` 等稳定原因裁决。
- 没有转让的幂等窗口外保证变化；沿用 M11-01/M11-02 的既有边界。

## 关联

- 权威接入：[M11-02 · 地籍接入世界权威](RECORD-02-cadastre-authority.md)。
- 可见性：[M11-03 · 地籍可见性与宅基面板](RECORD-03-cadastre-visibility.md)。
- 裁决：[ADR-023 · 地籍与建筑归属分离](../../decisions/ADR-023-land-cadastre.md)、[ADR-028 · 建造与地籍权限](../../decisions/ADR-028-build-land-authority.md)。
- 阶段计划：[M11 PLAN](PLAN.md)。
