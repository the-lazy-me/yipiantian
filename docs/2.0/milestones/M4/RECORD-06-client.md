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

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 120 "$GODOT" --headless --path Game \
  --script "$PWD/tests/world_join_code_test.gd"
perl -e 'alarm shift; exec @ARGV' 280 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_client_scene_test.gd"
```

结果：`WORLD_JOIN_CODE_TEST checks=31 failures=0`；`M4_CLIENT_SCENE_TEST checks=15 failures=0`（连续复跑通过）。

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
- 加入码没有界面：目前只能从命令行传入，也没有“复制/粘贴”控件、二维码或剪贴板识别。
- 世界布局变化（房主改了岛屿）时客户端拒绝并提示重新加入，没有自动重建场景的流程；重连、离线排队、`authority_lost` 后自动恢复都未实现。
- 玩家身份仍是命令行参数：不给 `--player-id` 时是匿名成员，不能使用社交功能，也没有本地持久化的玩家档案。
- 联机模式下厨房、动物、院落编辑、相册与本地世界包导入导出被明确禁用；这些功能要等世界命令扩展到对应对象后才可能在联机世界里可用。
- 同一进程只能有一个 `WorldSession`（RPC 路径固定为 `/root/WorldSession`），因此测试在同进程内不能再开第二个成员；共享状态用服务器落盘结果验证。
- 只测 macOS 回环；Windows、真实局域网、防火墙、NAT、慢网络下的 20 秒加入超时与 30 秒校正节奏都未验证。
- 加入码含邀请秘密，是明文凭证：没有加密、没有单独撤销界面，泄露后只能更换邀请文件重启服务器。

## 关联

- 邀请与认证：[M4-02](RECORD-01-join.md)、[ADR-004](../../decisions/ADR-004-transport.md)。
- 同步与断线语义：[M4-03](RECORD-02-sync.md)；成员名单：[RECORD-05](RECORD-05-presence.md)。
- 部署入口：[M4-05](RECORD-04-deploy.md)。
- 阶段计划：[M4 PLAN](PLAN.md) M4-02、M4-03。
