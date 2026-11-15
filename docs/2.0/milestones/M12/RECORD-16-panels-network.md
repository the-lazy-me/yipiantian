# M12/M8 · 三面板真实网络 UI 联调（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M12 或 M8 验收完成。前置：[RECORD-10 · 参与制度真实网络](RECORD-10-participation-network.md)、[RECORD-13 · 交战面板](RECORD-13-conflict-panel.md)、[RECORD-14 · 交战真实网络](RECORD-14-conflict-network.md)。

## 目的

已有参与制度、交战、公共项目面板测试只使用桩数据，网络测试又绕过面板。本切片把三个真实面板实例按 `Game/scenes/main.gd` 的方式接到真实 `WorldClient` 和真实 `world_server.gd` 上，验证：

1. 参与面板由权威 `participation_result` 驱动，房主声明与成员同意经 RPC 17/18 落到权威；
2. 交战面板打开时先刷新参与视图并显示制度表头，成员填表后的 engage 经 RPC 19/20 成功；
3. 公共项目面板的登记、承诺、基金建成经 RPC 21/22 成功；
4. 面板不在本地放行：发送前与拒绝后保持权威最后状态，刷新和关闭不产生额外写入。

## 实现

新增 `tests/panels_network_integration_test.gd`。全部产物在 `.local/verification/panels-network-<usec>/`。

- 启动真实 `Game/world/world_server.gd`，回环 WSS，`--host-player=PLAYER_A`；
- 依次连接两个具名成员和一个访客（`WorldClient` 的会话节点固定为 `/root/WorldSession`，因此逐个连接）；
- 面板只创建一次并挂到场景树根，信号接线与 `main.gd` 一致：
  - `client.participation_result → participation_panel.apply_result`；
  - `client.conflict_result → conflict_panel.apply_result`；
  - `client.public_works_result → public_works_panel.apply_result`；
  - `client.participation_result → conflict_panel.set_participation`（只读制度表头）；
  - 面板 `*_action` / `refresh_requested` 转发为对应 `client.request_*`；
- UI 操作通过面板内真实控件完成：填写 `LineEdit` / 选择 `OptionButton` 后触发 `Button.pressed`、确认 `ConfirmationDialog` 的 OK 按钮；
- 夹具使用真实通道：账户、规则商人、购买粮草、招募单位、组织、基金缴入；单位为 1 人民兵，双方各买 8 份粮草；
- 房主的防守方同意由测试直接发送参与请求。参与面板按设计对房主隐藏玩家操作区，这是既有 UI 语义，不是本切片新增的接线缺口；成员同意仍由面板控件完成。

未修改生产代码。

## 覆盖

| 要求 | 断言 |
|---|---|
| 1 参与面板 | 真实 state 答复后渲染和平制度、房主 A（标注“你”）、空参与者；房主区可见、玩家区隐藏。通过面板填写 limited 声明（区域、窗口、双方上限）后，权威答复 `ok` 且 revision=1，面板渲染“有限冲突 / 第 1 版 / 在线上限 5”、区域行、窗口行和参与者行；`participation.json` 记录 revision=1。成员 B 的面板渲染同一制度、区域、窗口和房主防守方行；通过面板选择进攻方并同意后，权威参与者行记录 B 为 attacker、同意第 1 版，面板渲染该行。访客的拒绝原因按权威 `reason_text` 原样显示 |
| 2 交战面板 | 打开时先执行 `set_participation(participating_panel.view)`，再请求 conflict state 和 participation state；真实参与视图刷新后面板显示“有限冲突 / 在线上限 5”和房主 A。B 填写防守者 A、双方单位与坐标；点击 Engage 只打开确认框、不发请求，视图保持权威最后状态；确认后权威 `ok`、action=engage、recent 含本次 command id，面板渲染近期结果和目标“累计损失 1/100”，状态行为“交战已结算。”；`conflicts.json` 目标损失为 1 |
| 3 公共项目面板 | A 打开面板读取空项目表；通过面板登记 `road_panel_ui`（石板路），权威答复 `ok` 并渲染未建、已承诺 0、固定成本覆盖 0；面板承诺 120 后权威 `funded`，渲染已足额；用组织基金建成后权威 `built`、`built_utc > 0`，面板渲染已建成和建成时间，状态行为“公共项目已建成。”；`public_works.json` 状态为 built，基金文档余额 0、已支出 120 |
| 4 不本地放行 | 交战与公共项目在发送前保存面板视图和权威文件字节；点击 Engage 未确认时不发送；访客的参与同意、engage、项目登记均被权威拒绝为 `forbidden`，面板状态行与权威 `reason_text` 完全一致，视图仍等于权威最后状态（参与视图比较忽略会前进的 `now_utc`），交战 recent 数与目标损失不变，项目列表不新增本地行；随后刷新三个面板并关闭，`participation.json`、`conflicts.json`、`public_works.json`、`public_funds.json` 字节均不变 |

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 420 "$GODOT" --headless --path Game \
  --script "$PWD/tests/panels_network_integration_test.gd"
```

原始末行（本机连续两次完整运行）：

```text
PANELS_NETWORK_INTEGRATION_TEST checks=148 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/panels-network-421966
PANELS_NETWORK_INTEGRATION_TEST checks=148 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/panels-network-453448
```

## 缺陷

未发现生产缺陷，未修改 `Game/` 下任何文件。测试首次运行时发现的 9 项失败均在本测试的夹具和断言中：基金答复的 `state.funds` 是数组而文档是映射；项目/基金文档有 `state` 外层；交战目标上限来自 `CONFLICT_TARGET_LOSS_CAP=100` 而非参与制度上限；第二个成员不需要重复开规则商人；参与视图的 `now_utc` 会推进；局部变量计数不能用于信号回调。修正后连续两次全绿。

## 未覆盖

- macOS TCC（辅助功能、屏幕录制）授权流程：测试为无头进程，未触发也不需要系统权限提示。
- 真实鼠标/触控板点按与键盘焦点遍历：测试直接触发控件 `pressed` 信号和对话框按钮，不经过 OS 级输入事件；面板自身的 Esc/焦点行为仍由三个面板单测覆盖。
- Windows：未在目标环境运行；日志断言按设计仅在非 Windows 执行，状态文件与文档字节断言逻辑平台无关。
- 真实网络抖动、丢包、断线重连后的面板刷新与多窗口并发不在本切片内。
- 未覆盖真实玩家在面板打开期间收到他人并发写时的视觉刷新时序。

## 关联

- 参与制度网络：[RECORD-10 · 参与制度真实网络](RECORD-10-participation-network.md)。
- 交战面板：[RECORD-13 · 交战面板](RECORD-13-conflict-panel.md)。
- 交战网络：[RECORD-14 · 交战真实网络](RECORD-14-conflict-network.md)。
- 阶段计划：[M12 PLAN](PLAN.md)。
