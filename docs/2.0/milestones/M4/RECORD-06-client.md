# M4-06 · 加入码与客户端入世（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M4 或 M4 验收完成。前置：[M4-02 创建与加入](RECORD-01-join.md)、[M4-03 同步与重连](RECORD-02-sync.md)、[M4-05 服务器部署](RECORD-04-deploy.md)。

## 实现

此前的联机只存在于测试与无头服务器里：客户端节点会重建状态，但主场景没有接上，玩家也拿不到“地址 + 邀请 + 证书”这一整套材料。本切片把这两件事接起来。

- **加入码**（`Game/world/world_join_code.gd`）：一段可粘贴的字符串，包含端点、证书的服务器名、证书 PEM 与 `WorldInvite` 邀请码。
  - 前缀 `FARMJ1.`，整体 base64，解析前限制长度并校验 base64 字母表，避免把粘贴错误当成引擎错误刷屏。
  - 端点只接受 `wss://`，校验主机、端口范围与空白；服务器名不能为空或含分隔符；证书必须能被 `X509Certificate.load_from_string()` 加载。
  - `tls_options()` 用同一份证书生成 `TLSOptions.client(cert, server_name)`，因此**解析时校验过的证书就是连接时信任的证书**，自签名的局域网服务器不需要玩家手动导入证书。
  - 邀请本身仍走 `WorldInvite.decode()`，权限、世界 ID、有效期与一次性规则没有第二套实现。
- **服务器入口**（`Game/world/world_server.gd`）：新增 `--join-url=`。首次运行（生成邀请的那一次）会在 `WORLD_SERVER_READY` 里多打印一个 `join_code`；重启不会重印，和邀请码的既有规则一致——日志里出现过的秘密不应该再出现第二次。
- **客户端生命周期**（`Game/world/world_client.gd`）：一个节点负责传输与会话，场景只读状态。
  - 会话节点 `WorldSession` 直接挂在树根下：RPC 按节点路径寻址，挂在场景子树里会找不到宿主。
  - 传输层 `CONNECTED` 之后才回答认证挑战（HMAC-SHA256，秘密不上线），随后等宿主的 `summary`。
  - 世界时钟取最后一次快照的 `now_utc` 加上本地经过的毫秒数，保持宿主“从启动瞬间单调推进”的性质，墙钟跳变不会让作物倒退。
  - 每 30 秒主动拉一次摘要做校正；命令与广播则在本地按同一套确定性规则重放，不为每个动作传整份快照。
- **主场景接入**（`Game/scenes/main.gd`）：`remote` 与 `remote_seed` 在场景进树前由启动场景填入。
  - 岛屿形状取自世界文档的 `layout`，不读本地存档；没有本地存档也能进世界。
  - 土壤动作只把命令交给权威，收到成功回复后才在本地重放同一命令；拒绝时用一行提示说明原因（`forbidden`、`command_conflict`、`read_only`、`save_*` 等有中文文案）。
  - 联机模式下 `_save_farm()` 直接返回成功但不写盘；导出/导入世界包被拒绝；院落编辑、厨房、动物、相册这些**只存在于本地存档**的功能给出可见理由而不是静默分叉。
  - 连线断开时画面停在最后一次确认的状态（符合 M4-03 的“断线显示最后确认状态”），提示里带原因。
- **启动场景**（`Game/scenes/startup.gd`）：`--join-code=` 时先连接、拿到第一份权威状态，再把世界交给农场场景；首次运行的画质测量在联机模式下不执行，因为那是对本机的测量，与世界无关。连接失败显示可读原因并保留“重试加载”。

### 访客照料码（追加）

开房此前只产出成员加入码，玩家指南因此写着“当前游戏内没有生成访客加入码的入口”。本追加小节补上这枚码，且生成留在权威进程内：

- `Game/world/world_server.gd` 在注册成员邀请后，再注册一条独立 id 的 `visitor` 授权。访客密钥由 `invite.bin` 以 HMAC-SHA256 域分离确定性派生（不是新密钥文件），因此轮换邀请会一起轮换访客码，授权表重启重建时同一份邀请仍得到同一枚访客码。
- 指定 `--join-url` 时，权威把端点、证书与访客授权编码成完整的 `FARMJ1.` 加入码，写入数据目录的 `visitor-join-code.txt`；客户端不读取邀请密钥来拼装访客授权。该文件在每次启动时重写，`world_hosting.start()` 会先清掉上一轮残留，避免把旧码当成本轮答案。`--join-url` 为空时不生成该文件；编码或写入失败只打印一行 `WORLD_SERVER_VISITOR_CODE_ERROR`，世界继续运行。
- `Game/world/world_hosting.gd` 的 `poll()` 把访客码视为可选：文件缺失、解析失败或角色不是 `visitor` 时返回空字符串 `visitor_join_code`，房间仍然成功。成员加入码与“进入这间房”不受影响；面板用状态行提示“访客加入码暂不可用，重启房间再试”。
- `Game/ui/room_panel.gd` 增加“访客照料码”区块：独立只读输入框与复制按钮，说明“只能浇水、除草”，并保留“加入码就是进入凭证、泄露后需更换 `invite.bin`、当前没有撤销界面”的提示。成员码与访客码分别展示，不互相替换；没有访客码时整个区块隐藏。
- `Game/scenes/startup.gd` 把两枚码一起交给面板；成员码仍自动复制到剪贴板，访客码由玩家按需复制。

验证：`tests/visitor_join_code_test.gd` 启动真实房间进程，断言两枚码都可解析、角色分别为 `member` / `visitor`、id 与密钥不同、访客权限只含浇水与除草；随后在同一权威上先以成员码加入、再以访客码加入，证明两次注册没有互相覆盖。它还覆盖无访客码目录（房间仍成功、成员码仍产出）和未指定 `--join-url` 的服务端（不写出访客码文件）。`tests/startup_room_test.gd` 增加面板入口与文案断言，`tests/room_panel_scene_test.gd` 覆盖纯 UI 展示、复制以及“没有访客码仍可进入”。结果见下方“验证”小节。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 120 "$GODOT" --headless --path Game \
  --script "$PWD/tests/world_join_code_test.gd"
perl -e 'alarm shift; exec @ARGV' 280 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_client_scene_test.gd"
```

结果：`WORLD_JOIN_CODE_TEST checks=31 failures=0`；`M4_CLIENT_SCENE_TEST checks=15 failures=0`（连续复跑通过）。访客码追加后：`VISITOR_JOIN_CODE_TEST checks=28 failures=0`（含无访客码目录与无 `--join-url` 服务端两条可选路径）、`STARTUP_ROOM_TEST checks=27 failures=0`、`ROOM_PANEL_TEST checks=35 failures=0`；受影响的既有用例 `WORLD_INVITE_TEST checks=33`、`WORLD_JOIN_CODE_TEST checks=31`、`M4_HOSTING_TEST checks=25`、`M4_SERVER_TEST checks=79` 也全部无失败。

| 用例 | 实际观察 | 结果 |
|---|---|---|
| 编解码往返 | 端点、服务器名、证书逐字节一致，内嵌邀请的秘密与原邀请相同 | 通过 |
| TLS 选项 | 解析出的证书能构造 `TLSOptions.client` | 通过 |
| 粘贴容错 | 跨行与首尾空白仍可解析 | 通过 |
| 拒绝路径 | 空码、错前缀、截断、非 base64、`ws://`、带空白的主机、无主机、端口 0/99999/非数字、空服务器名、非 PEM、超大证书、坏邀请各自具名拒绝 | 通过 |
| 编码拒绝 | 无邀请、非加密端点、无法加载的证书都不生成码 | 通过 |
| 真实入世 | 测试启动真实 `world_server.gd` 子进程，用加入码连接，收到权威状态并渲染 | 通过 |
| 世界时钟 | 场景时钟与世界时钟相差约 5 秒（启动耗时），不是本机随意取值 | 通过 |
| 收获往返 | 点击成熟地块 → 权威回复 `ok=true, reward=1, sequence=1` → 本地应用，地块变空 | 通过 |
| 落盘 | 停止服务器后 `farm.json` 中 `harvested.greens == 1`，只结算一次 | 通过 |
| 本地编辑拒绝 | 打开院落编辑被拒绝，`decoration_layout.active == false`，提示含“房主” | 通过 |

另外用真实游戏进程人工验证了一次启动链路：对一个运行中的服务器执行

```sh
"$GODOT" --headless --path Game -- --join-code="FARMJ1…" --player-name=阿青
```

stdout 依次出现 `STARTUP_STAGE progress=8 正在进入世界…`、各阶段构建、`FARM_REMOTE world=world-manual role=member now=1800000004`。这是人工观察，不是自动化用例（见未覆盖）。

`M4_PRESENCE_TEST`（见 [RECORD-05](RECORD-05-presence.md)）在同一个会话通道上验证了成员名单推送，可供后续界面使用。

## 未覆盖

- 启动场景的 `--join-code` 入口没有自动化用例：`--quit-after` 在这个工程里不能可靠结束真实游戏进程，测试改成直接组装 `WorldClient` + 主场景（上面的 15 项）。启动链路的参数解析与转交只有人工证据。
- 加入码仍没有二维码或剪贴板自动识别；开房面板可以复制成员码与访客码，但没有撤销界面，撤销只能手动轮换 `invite.bin` 并重启（两枚码一起失效）。
- 世界布局变化（房主改了岛屿）时客户端拒绝并提示重新加入，没有自动重建场景的流程；重连、离线排队、`authority_lost` 后自动恢复都未实现。
- 玩家身份仍是命令行参数：不给 `--player-id` 时是匿名成员，不能使用社交功能，也没有本地持久化的玩家档案。
- 联机模式下厨房、动物、院落编辑、相册与本地世界包导入导出被明确禁用；这些功能要等世界命令扩展到对应对象后才可能在联机世界里可用。
- 同一进程只能有一个 `WorldSession`（RPC 路径固定为 `/root/WorldSession`），因此测试在同进程内不能再开第二个成员；共享状态用服务器落盘结果验证。
- 只测 macOS 回环；Windows、真实局域网、防火墙、NAT、慢网络下的 20 秒加入超时与 30 秒校正节奏都未验证。
- 两种加入码都是明文凭证，没有加密、没有单独撤销界面；泄露后只能更换邀请文件重启服务器（成员码与访客码一起失效）。

## 关联

- 邀请与认证：[M4-02](RECORD-01-join.md)、[ADR-004](../../decisions/ADR-004-transport.md)。
- 同步与断线语义：[M4-03](RECORD-02-sync.md)；成员名单：[RECORD-05](RECORD-05-presence.md)。
- 部署入口：[M4-05](RECORD-04-deploy.md)。
- 阶段计划：[M4 PLAN](PLAN.md) M4-02、M4-03。
