# M11-03 · 规则决议面板真实 WSS 端到端

执行日期：2026-11-16。状态：切片完成，不表示 M11-03 或 M11 验收完成。前置：[M11 PLAN](PLAN.md)、[RECORD-12 · 规则决议权威与 RPC](RECORD-12-resolutions-authority.md)、[RECORD-13 · 规则决议面板](RECORD-13-resolutions-panel.md)、[RECORD-16 · 决议效果权威](RECORD-16-resolution-effects-authority.md)。

## 问题

RECORD-13 的面板只在直接构造视图和假远程对象下验证，RECORD-12 的 RPC 27/28 只在 `WorldClient` 直连下验证，RECORD-16 的税费效果只在权威单元测试里检查。三者之间缺少一条真实链路：玩家在面板上提案、表决、关闭、生效，权威答复驱动面板刷新，`effects.tax_rate_permille` 真的变化，拒绝文案原样回到面板。RECORD-13 的「未覆盖」第一条正是这条缺口。

本切片先补夹具，随后修掉夹具暴露的一处显隐不足：面板曾把 `is_member` 当作写权限，访客因此看到成员专属按钮。修复新增独立的 `can_write` 视图字段，`is_member` 保留“已加入”的原义。

## 边界

- 新增 `tests/resolution_panels_network_test.gd` 与本记录。
- 修复显隐不足：`Game/world/headless_world.gd`（`resolutions_view()` / `execute_resolution()` 新增 `can_write`）、`Game/world/world_host.gd`（`_resolution_can_write()`，`_resolution_state()` / `_with_resolution_state()` 传参）、`Game/ui/resolutions_panel.gd`（写入按钮与顶栏改看 `can_write`）。
- 更新 `tests/resolutions_panel_test.gd`（已加入访客视图）、`tests/resolution_authority_test.gd`（连接层 `can_write`）与 RECORD-12 / RECORD-13 的字段表。
- 未修改 `Game/world/world_projection.gd`、`Game/world/*_state.gd`、`Game/scenes/**`、`.github/**`；CI 登记由后续批次统一处理，本切片不改 `rule-tests.yml`。
- 产物只写 `.local/verification/resolution-panels-network-<ticks>/`。
- 面板按 `main.gd` 的方式接线：`resolution_action` / `refresh_requested` 转发给 `WorldClient.request_resolutions()`，`resolutions_result` 直接连 `panel.apply_result`。测试因此同时覆盖连接层与视图层；面板不新增 headless 入口。

## 场景

真实 `world_server.gd` + loopback WSS，三名具名成员（不同安装凭据）与一名访客依次单独连接；`WorldClient` 总是创建 `/root/WorldSession`，所以一次只开一条连接。

1. 成员 B 在面板里填表提案（`tax`、窗口 20 s、生效 = 窗口结束 + 预告 + 60 s）。权威答复替换整份视图，`Resolution_res_panel_net_tax` 行出现，状态 `proposed`，`resolutions.json` 落盘。
2. 紧接着用直连关闭：必然早于窗口结束，权威返回 `window_open` 与文案，面板 `Status` 逐字显示，行仍 `proposed`。
3. 成员 A 与成员 C 各自通过面板赞成；等权威时钟跨过 `vote_start_utc` 后点击，答复把计数推到 1、2，面板渲染「赞成 2」。
4. 等权威时钟跨过 `vote_end_utc`，面板关闭投票 → `passed`、修订 2；直连提前生效返回 `too_early` 与文案。
5. 停掉权威，以 `effective_utc + 30` 重启（真实等待预告期 3600 s 不现实；RPC 与规则检查保持真实），面板生效成功：`rules_version=1`、行 `effective`、版本差异出现、`effects.applied_version=1`、`effects.tax_rate_permille=10`；`resolution_effects.json` 只有一条应用记录。
6. 用面板自己写进日志的 `activate` command id 重放：返回 `duplicate`，`rules_version` 仍为 1，费率仍为 10，`resolutions.json` 与 `resolution_effects.json` 都逐字节不变。
7. 访客读取：`can_write=false` 且 `is_member=true`（隐私分级仍下发计票人数），顶栏写作访客，四个成员专属按钮全部不可见，也看不到投票人身份；提案表单在可用视图下可见，访客真实点按提案 → `forbidden`、权威文案逐字显示、面板视图不变、本地不新增行；刷新仍是只读且不改两份文档。成员视图则 `can_write=true`，生效行上撤案按钮按提案人/赞成者规则出现。
8. 最终重启：行、规则版本与税率保留，面板重新渲染，两份文档逐字节不变。

## 关键选择

- **用重启时钟而不是等待 3600 s**：预告期是真实规则，夹具不缩短它，而是停服后以更晚的 `--now-utc` 重启同一目录，与 `resolution_network_test` 的做法一致。这样生效与效果的校验仍是真实规则，不引入测试专用旁路。
- **等待都有上限**：权威时钟轮询每次间隔 1 s（命令令牌桶 20 突发 / 1 每秒），单点上限 30 s；服务端启动 20 s、连接 20 s、答复 15 s、停服 20 s。整次运行实测约 32 s，远低于 CI 180 s 看门狗。
- **读取文档先轮询可解析**：`_json_ready()` 用显式循环而不是在 `Callable` 内写入，因为 GDScript lambda 按值保存局部变量，闭包里写入的文档不会到达调用方（首版即因此误报四条）。
- **访客探针走面板而不是只调 RPC**：提案表单对所有 `available` 视图开放，因此访客能真实触发一次写入意图，让 `forbidden` 文案经 `apply_result` 回到面板；表决/生命周期按钮在该行不可见，故不假装点按。
- **先补写权限事实，再改面板显隐**：`is_member` 的语义是“已加入”，RECORD-12 的隐私分级靠它下发计票人数；面板此前误把它当写权限，访客于是看到表决按钮。本切片新增并行的 `can_write`（由 `WorldHost` 按连接解析：成员角色、非只读、具名身份三者同时成立），面板改看它，`is_member` 保留原义。
- **重放用的是面板生成的 command id**：从 `resolutions.json` 的 `commands` 日志取 `action=activate` 的那一行，保证重放的就是面板真实发过的命令，而不是另造 id。

## 验证

```text
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 240 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/resolution_panels_network_test.gd"
```

两次完整运行的最后一行：

```text
RESOLUTION_PANELS_NETWORK_TEST checks=139 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/resolution-panels-network-374318
RESOLUTION_PANELS_NETWORK_TEST checks=139 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/resolution-panels-network-368733
```

回归：

```text
RESOLUTIONS_PANEL_TEST checks=91 failures=0
RESOLUTION_NETWORK_TEST checks=48 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/resolution-network-337461
RESOLUTION_AUTHORITY_TEST checks=128 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/resolution-authority-652403
RESOLUTION_EFFECTS_AUTHORITY_TEST checks=48 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/resolution-effects-authority-558179
HEADLESS_WORLD_RUNTIME_TEST checks=83 failures=0
FONT_COVERAGE_TEST checks=1272 failures=0 missing=0
```

字体：本记录与测试新增的中文用字都在现有子集内，未改字体文件；字体覆盖测试 `missing=0`。

## 未覆盖

- **`can_write` 只是显示性事实**：面板按它摆放表决/关闭/生效/撤销按钮，但它不参与授权。每次写入仍由 `WorldHost.resolutions_for_member()` 重新判定角色、只读与具名身份，客户端视图即使被改写，也只能收到 `forbidden`/`read_only`/`no_player`。`is_member` 保持“已加入”的原义，继续决定计票人数；两者互不替代。
- **真实鼠标点按、窗口焦点与渲染外观**：测试在 `SceneTree` 里挂载真实面板并直接触发按钮信号，没有真实窗口；视觉与布局仍由窗口模式测试覆盖。
- **摘要推送**：决议变更不走摘要，成员只在自己的答复里看到视图；另一名成员的存活连接不会主动刷新。夹具每阶段重新连接，未验证长连接下的被动刷新。
- **Windows 实机文件系统、真实多端并发与真实 3600 s 预告期等待**。
