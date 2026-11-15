> 与提交 cba4597 对应的实现状态（部署参数、世界名、只读与面板接线已按 e72b54f…cba4597 修正），未验收

# M13-05 · 玩家与自托管指南记录（RECORD-06）

日期：2026-11-15。状态：文档初稿完成并已提交，**未验收**。编写期间发现的部署缺陷已在下表列出的提交中修复；文档本身随本次提交一并登记。

## 交付文件

| 文件 | 面向 | 内容 |
|---|---|---|
| `docs/2.0/release/player-guide.md` | 玩家 | 启动、操作、天气、市场、银行、联机、邻居权限、宅基、设置、存档、故障 |
| `docs/2.0/release/self-host.md` | 自托管运营者 | 参数、数据目录、首次材料、状态、加入、防火墙、只读/停止、锁、备份、错误 |
| `docs/2.0/release/upgrade-rollback.md` | 玩家/运营者 | 版本契约、升级前清单、快照命令、回滚、不可逆红线、演练标准 |
| `docs/2.0/release/feedback.md` | 玩家/运营者 | 日志位置、关键行、最小复现、禁止上传的材料、发送前自检 |

每个文件首行写明对应的提交与“未验收”。

## 事实来源

文档中的行为按下表逐项核对；参数、默认值、提示文案均来自代码或已提交记录，没有补写未实现能力。

| 文档 | 代码/记录依据 |
|---|---|
| player-guide | `Game/scenes/startup.gd`、`Game/scenes/main.gd`、`Game/scenes/farm_hud.gd`、`Game/ui/room_panel.gd`、`Game/ui/social_panel.gd`、`Game/ui/market_panel.gd`、`Game/ui/bank_panel.gd`、`Game/ui/build_panel.gd`、`Game/ui/game_menu.gd`、`Game/farm/crop_catalog.gd`、`farm_state.gd`、`nature_state.gd`、`presentation/weather_mood.gd`、`presentation/disaster_mood.gd`、`economy_catalog.gd`、`market_state.gd`、`loan_state.gd`、`building_catalog.gd`、`settings_store.gd`、`social/player_profile.gd`、`farm_store.gd`、`nature_store.gd`、`world_invite.gd`、`world_join_code.gd`、`world_client.gd`、`world_hosting.gd` |
| self-host | `Game/world/world_server.gd`（参数、材料、锁、只读、状态、退出码、日志行）、`Game/world/world_hosting.gd`（房间端口与停止）、`Game/farm/farm_store.gd`（路径安全检查）、[M4-05 部署记录](../milestones/M4/RECORD-04-deploy.md)、[M4-07 房间记录](../milestones/M4/RECORD-07-rooms.md) |
| upgrade-rollback | `Game/farm/farm_store.gd`（v27）、`nature_store.gd`（v2）、`social_store.gd`（v2）、`world/territory_store.gd`（v1）、`settings/settings_store.gd`（v1）、`social/player_profile.gd`（v1）、`farm/world_package.gd`（格式 3）、`farm/world_transfer.gd`、`farm/v27_importer.gd`、[M13-03 恢复演练](RECORD-03-recovery.md) |
| feedback | `Game/farm/farm_store.gd`、`Game/scenes/main.gd`、`Game/scenes/startup.gd`、`Game/scenes/startup.gd` 的 `STARTUP_*`、`Game/world/world_server.gd` 的 `WORLD_SERVER_*`、`Game/farm/world_transfer.gd` 的 `WORLD_TRANSFER`、`Game/settings/settings_store.gd` |

补读的既有记录：`docs/2.0/milestones/M13/PLAN.md`（M13-05）、`docs/2.0/milestones/M13/RECORD-01-export.md`、`docs/development-setup.md`、`docs/release/来源与发行核验.md`、`发行材料/使用说明.txt`。

## 本机实测（macOS）

在 `/private/tmp/m13-probe/` 用真实 `world_server.gd` 运行，未改动仓库；误写在 `Game/reldir` 的探测材料已删除。

| 探测 | 实际结果 |
|---|---|
| 首次运行 + `--join-url` | `WORLD_SERVER_READY`，`opened=created`，`invite_created=true`，含 `invite_code` 与 `join_code`；退出 `save=saved` |
| 用已有 `invite.bin` 重启 | 不再打印邀请/加入码；残留 `stop` 被清除；启动成功 |
| 已有目录放 `read-only` 重启 | 状态 `read_only=true`，退出 `save=read_only_skipped`，没有写盘；`read-only` 文件保留 |
| 第二个实例同目录 | `WORLD_SERVER_ERROR {"reason":"data_dir_locked"}`，退出码 2 |
| 强杀后立即重启 | `data_dir_locked`，退出码 2；等待 31 秒后启动成功 |
| `--port=0` / `--port=abc` | `invalid_option`，退出码 2 |
| `--port=70000` | 旧实现被夹到 65535 后启动；现已改为 `invalid_option` 退出 2，且校验先于建目录（`97989e2`） |
| 相对 `--data-dir` | 旧实现报 `relative_data_dir` 后仍继续并写出材料；现已补 `return`，只报 `relative_data_dir` 并退出 2，不建目录也不写材料（`e72b54f`） |
| `--data-dir=/tmp/...` | `/tmp` 是符号链接，`world_open` 返回 `load_unsafe_path` |
| 1 字节 `invite.bin` | 重新生成邀请并打印新的 `invite_code` / `join_code` |
| 证书 | RSA 2048，自签，`CN=localhost`，有效期 2014-01-01 至 2034-01-01，SHA-256 指纹 32 段 |
| 既有目录改 `--world` | 旧实现直接按新 ID 启动；现首次成功启动把世界名写入 `world-id.txt`，改值以 `world_mismatch` 拒绝，删除该文件后才按新名启动（`cba4597`） |

这些探测只覆盖服务端入口与材料，没有在 Windows 实机重复。

## 提交与工作树

- 初稿在 `f518e98` 上完成，当时核对到 `0066b2e`；指南编写期间列出的部署缺陷随后逐项修复并提交：`e72b54f`（相对数据目录后立即返回、存档路径文档）、`130e5de`（社交授权与屏蔽边界）、`e20dc97`（食袋展示路径、面板 Esc、宅基只读）、`b284f97`（只读标记先于世界打开）、`97989e2`（参数越界即拒绝、校验先于建目录）、`b9076bc`（玩家档案损坏归档）、`cba4597`（世界名固定）、`af0ffd4`（礼物重放持久去重）、`f67d876`（v27 边界夹具改用文档时间上界）。
- 因此四份指南现在对应的是“`cba4597` 的部署行为 + `af0ffd4` 的礼物语义”；`self-host.md` 的参数表、`world_mismatch`、`world-id.txt`、相对路径与宅基只读段落已按新行为改写，`player-guide.md` 第 6 节的访客宅基描述同步更新。
- 这些提交已推送到 `origin/main`；`rule-tests.yml` 由手动 dispatch 触发，本记录提交后另行派发并在结果出来后登记。
- [M4-05 部署记录](../M4/RECORD-04-deploy.md) 的 `save` 描述、只读语义与检查项数量已随 `b284f97`、`97989e2`、`cba4597` 同步（当前 79 项）。
- [M13-03 演练](RECORD-03-recovery.md) 对应 `7e0fd96` 与当时工作树，结论仍成立，但其证据不能当作当前 HEAD 的重新演练。
- `docs/development-setup.md` 的存档路径已在 `e72b54f` 改为 `user://farm-v27/`。

## 未覆盖

- **真实用户试用**：没有真实玩家按本指南完整走一遍；文案是否易懂、步骤是否遗漏未经用户验证。
- **Windows 实机**：所有命令只在 macOS 实测；Windows 启停、路径、防火墙、开房与恢复未在实机执行。CI 只覆盖部分无头服务端/客户端用例。
- **多语言**：当前游戏与文档只有中文，没有其他语言版本或翻译流程。
- **局域网以外**：NAT、跨网段、公网、真实防火墙组合未验证。
- **导出构建作为服务端**：当前不支持，文档只写拒绝行为；没有导出服务器包的步骤。
- **Linux**：没有运行环境，未验证。
- **签名与公证**：`RECORD-01` 的产物未签名、未公证、未发布；文档没有发行承诺。
- **2.0 格式迁移**：当前不存在 2.0 格式，`upgrade-rollback.md` 只写前置条件与回滚，没有可执行的“升级到 2.0”步骤。
- **真实存档演练**：`RECORD-03` 使用测试夹具；本次没有用真实玩家存档重跑导出/导入/回滚。
- **界面证据**：没有截图、录屏或可访问性检查；玩家指南按代码文案编写。
- **长时驻留**：M13-02 的 soak 记录不属于本次任务，本记录不引用其未核验结论。

## 需要登记的内容

1. ~~**M4-05 部署记录的 `save` 值需修正**~~（已修正：`b284f97`）：该记录已在 `04f44a7` 提交，只读持久化、目录锁与停写语义与 `self-host.md` 一致；但它写“正常保存为空”，而 `world_server.gd` 的 `_write_status(..., saved.ok, str(saved.get("kind", "")))` 和 `farm_store` 的 `{"ok": true, "kind": "saved"}` 表明正常退出应为 `save=saved`，本次实测也得到 `save=saved`；只有只读退出是 `read_only_skipped`。需要改 M4-05 该行，而不是改实现。
2. ~~**修正开发文档存档路径**~~（已修正：`e72b54f`）：`docs/development-setup.md` 写 `user://farm/`，代码为 `user://farm-v27/`。
3. ~~**`world_server.gd` 相对路径退出缺陷**~~（已修正：`e72b54f`，`m4_server_test` 覆盖）：`--data-dir` 相对路径在 `relative_data_dir` 后只调用 `quit(2)` 而没有 `return`，仍会写材料并继续到 `world_open`；文档已警告，代码应补 `return` 并避免写材料。
4. **首次运行日志泄露凭证**：`WORLD_SERVER_READY` 含 `invite_code`/`join_code`，默认日志与 `--log-file` 都会保存；feedback 已要求不要上传，但产品侧可考虑脱敏或明确提示。
5. **邻里邀请无界面入口**：`SocialState.invite/accept` 与权威动作存在，但 `social_panel` 没有“发起邀请”按钮，正常游戏无法建立联系人；文档标为尚未提供，需决定是否纳入 M13-05 范围。
6. **访客加入码无生成入口**：协议支持 `visitor`，服务端与房间只发 `member` 邀请；文档标为尚未提供。
7. ~~**`--world` 改值会重标既有目录**~~（已修正：`cba4597`，`world-id.txt` 固定世界名）：实测直接以新 ID 启动，旧加入码失效；是否应拒绝或要求显式确认，需要产品决定。
8. ~~**`--port` 超上限被夹到 65535**~~（已修正：`97989e2`，越界拒绝且先于建目录）：实测 `70000` 会启动；是否改为拒绝，需要决定。
9. ~~**宅基面板未传只读标志**~~（已修正：`e20dc97`，访客看到只读面板与原因）：`_refresh_homes()` 调 `build_panel.present()` 时没有传 `read_only`，访客能看到可点按钮但会被权威拒绝；文档按实际行为写明。
10. **Windows 实机验证**：服务端启停、自托管、开房、导入/回滚都需要 Windows 真机证据。
11. **真实用户试用与多语言**：需要在发布候选上安排，当前没有证据。
12. **M13-05 与 M13 状态**：文档已产出，但仍未验收；完成评审后再更新 `docs/2.0/milestones/M13/PLAN.md` 与 `rules/project-context.md`。
13. **文档对应的提交**：并行任务会继续推进 HEAD；这四份文档与本文固定对应 `0066b2e`，后续行为变化需重新核对并更新头部。
