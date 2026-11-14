# M4-07 · 启动界面开房与加入（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M4 或验收完成。前置：[M4-02 创建与加入](RECORD-01-join.md)、[M4-05 服务器部署](RECORD-04-deploy.md)、[M4-06 加入码与客户端](RECORD-06-client.md)。

## 问题

加入码与客户端入世都已完成，但玩家只能用命令行 `--join-code=` 进入世界；开着游戏的人既拿不到自己的加入码，也无法把加入码交给别人。也就是说，前面几个切片在测试里能跑，在游戏里不能。

## 实现

### 由游戏启动权威（`Game/world/world_hosting.gd`）

一个进程只有一个 `SceneMultiplayer`，客户端不能在同一进程里既当权威又当玩家。因此“开房”= 启动一个无头权威子进程，然后像对待朋友的服务器一样加入它。

- `start(directory, world, port)` 用当前引擎二进制加 `--headless --path Game --script Game/world/world_server.gd -- --data-dir=… --port=… --world=… --join-url=…` 拉起进程，不等待就绪。
- 开机前清掉上次留在房间目录里的 `server-status.json` 与 `stop`：否则第二次开房会在新进程写出状态前读到“已停止”，把旧答案当成这次的结果。
- `poll()` 读 `server-status.json`；`running` 时用 `invite.bin`、`server.crt` 与端点构造加入码，构造规则与服务器首次运行时打印的那张码相同（`WorldInvite` + `WorldJoinCode`），不另写一套。
- `url()` 优先选本机的私有局域网地址（`192.168.*`、`10.*`、`172.16–31.*`），没有就退回 `127.0.0.1`。对外只给可达地址，从不给 `0.0.0.0`。
- `stop()` 先写控制文件让权威自己收尾（它会把世界落盘），8 秒后仍未退出才 `kill`。每条命令都是落盘提交，所以强杀不会留下半个农场。
- 导出版不含服务器脚本，`start()` 在非编辑器构建里直接拒绝（`unsupported_build`），而不是开出一个永远连不上的房间。

### 面板（`Game/ui/room_panel.gd`）

`CanvasLayer`，只收集意图：`join_requested(code)`、`host_requested`、`local_requested`、`closed`。粘贴加入码、加入、开房、复制加入码、进入这间房、先自己种田，五个动作互斥状态由 `show_idle/show_joining/show_room/show_failure` 四个显式状态描述。空加入码在本地拒绝，不发请求。

### 启动场景接线（`Game/scenes/startup.gd`）

- 加载界面加了“联机：加入朋友的农场，或开一间房”。加入必须发生在农场场景组装之前：世界决定岛屿布局，而本地农场一旦跑起来就会自己写存档、自己走时钟。
- 面板打开或正在连接时，`_process` 不组装本地场景，即使资源线程已经加载完；关闭面板、选择“先自己种田”或连接失败后再继续。为此 `_connect_world(silent)` 增加了静默失败路径：面板自己展示原因，而不是复用启动失败的重试按钮。
- 开房成功后加入码写入剪贴板，并显示在只读输入框里，可以手动复制。
- 加入成功把 `_first` 置为 `false`：首次运行画质测量是对本机的测量，和世界无关。
- 房间进程的所有权转交给农场场景（`hosted_room`），农场场景退出时关闭它。启动场景退出时若房间还没转交（例如玩家选择“先自己种田”），也会关闭，不留下孤儿进程。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 120 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_hosting_test.gd"
perl -e 'alarm shift; exec @ARGV' 90 "$GODOT" --headless --path Game \
  --script "$PWD/tests/room_panel_scene_test.gd"
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/startup_room_test.gd"
```

结果：`M4_HOSTING_TEST checks=25 failures=0`；`ROOM_PANEL_TEST checks=24 failures=0`；`STARTUP_ROOM_TEST checks=20 failures=0`。

| 用例 | 实际观察 | 结果 |
|---|---|---|
| 参数拒绝 | 相对路径、端口 0、未启动时轮询各自具名拒绝 | 通过 |
| 真实开房 | 启动真实权威子进程，最长 30 秒内等到 `running` | 通过 |
| 端点 | 加入码端点为 `wss://`，主机是回环或私有地址，不是 `0.0.0.0` | 通过 |
| 材料 | 加入码解析出的端点、世界 ID、证书与房间文件一致，证书可构造 `TLSOptions.client` | 通过 |
| 落盘顺序 | 房间目录里有 `server-status.json`、`invite.bin`、`server.crt`；状态里的端口与 PID 和实际进程一致 | 通过 |
| 真实入世 | 用这张码连上房间，收到农场与世界时钟 | 通过 |
| 停止 | 停止后进程退出、`pid` 归零、状态文件记录 `stopped` 而非崩溃 | 通过 |
| 面板意图 | 空码本地拒绝；粘贴码去空白后请求加入；开房、复制、进入、先自己种田、收起各自只发出一个意图 | 通过 |
| 面板状态 | 连接中禁用第二次请求且不可改码；开房后显示可分享的码 | 通过 |
| 启动链路 | 加载界面点“开房”→ 出现加入码 →“进入这间房”→ 组装联机农场；房间随农场退出而关闭 | 通过 |
| 名字闸门 | 面板里没有名字时按“进入这间房”留在面板并说明缺什么，不会以匿名身份混进去 | 通过 |

`startup_room_test` 是这条链路唯一的端到端证据：它走真实启动场景、真实子进程、真实 WSS，不做网络替身。它第一次运行就抓到过一个真实缺陷：资源在开房前加载完时，`_resume_loading()` 因为 `_world_client != null` 直接返回，农场永远不会被装配；修掉这个条件后通过。

## 未覆盖

- 只在 macOS 上跑过。CI 的 Windows 作业会跑无头服务器与客户端测试，但“在 Windows 游戏里点开房”没有实机证据。
- 导出版不能开房：服务器入口是项目脚本，需要进入导出包并指定导出模板；目前给出明确拒绝。朋友加入导出版游戏不受影响（只需要 TLS + 加入码）。
- 加入码是明文凭证：任何拿到它的人都能以成员身份进入房间。没有单独撤销界面，泄露只能换 `invite.bin` 重启；面板也没有把码做成二维码或可点击链接。
- 房间固定落在 `user://rooms/world`，没有“选择房间名/存档位置/端口”的界面；端口在 20000–45000 里随机取空闲值，没有端口转发引导。
- 房主退出游戏就关房。没有“关掉游戏让朋友继续种”的常驻服务形态（那时应该用 M4-05 的部署入口）。
- 断线重连仍在另一份工作中；当前断线停在最后确认状态并提示原因。
- 局域网以外的连接（NAT、跨网段、防火墙）未验证，面板也没有提示需要放行端口。

## 关联

- 加入码与客户端：[M4-06](RECORD-06-client.md)；邀请与认证：[M4-02](RECORD-01-join.md)、[ADR-004](../../decisions/ADR-004-transport.md)。
- 部署入口与常驻服务：[M4-05](RECORD-04-deploy.md)。
- 阶段计划：[M4 PLAN](PLAN.md) M4-02、M4-04。
