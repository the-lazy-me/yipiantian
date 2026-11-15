# M6-04 · 灾害可见性

状态：切片完成（2026-11-15），未验收。范围：把 `NatureState`／`HeadlessWorld` 已有的当前灾害与预警接到玩家可见的 HUD，并用现有天气节点与昼夜节点做一次可逆、无新美术的场景提示；不改玩法、存档、网络消息、导航或居民作息。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/presentation/disaster_mood.gd` | 新增纯模块，不 preload 美术、不读时钟／存档／网络。`describe()` 接受当前灾害字典、预警字典与 `now_utc`，返回确定性单行文案、表现种类、强度与 warning 标记；未知种类、空值、非字典、非法时间、已过期事件返回空。`hud_visible()` 是 HUD 显隐的唯一判断。`apply_visual()` 在天气情绪之后叠加干旱／暴雨的小幅色光提示，并在会与当前天气矛盾时跳过。 |
| `Game/scenes/farm_hud.gd` | 在 `WeatherInfo`（top 92）下方新增只读 `DisasterInfo`（top 124），复用 `INK` 与 font size 16，无面板、图标或动画；`show_disaster()` 在未加载或文案为空时隐藏，位置不触碰顶部 `Notice`（top 28）与底部农事控制（top -66）。 |
| `Game/presentation/weather_atmosphere.gd` | 新增独立的 `set_disaster()`／`get_disaster()`：暴雨只在已经下雨时把同一发射器的粒子数从 700 提到 900，结束或改回干旱时恢复 700；从不调用 `set_weather()`。 |
| `Game/atmosphere/day_night.gd` | 新增独立的 `set_disaster()`／`get_disaster()`；`_apply_clock()` 在天气情绪之后调用 `DisasterMood.apply_visual()`。干旱只在非雨时加暖并压干远景，暴雨只在雨天再压暗；结束时下一次时钟重算自然恢复。 |
| `Game/scenes/main.gd` | `_sync_weather()` 在原有天气接线后读取 `_disaster_view()`。单机直接问本地 `NatureState.disaster_at()`／`next_disaster_at()`；共享世界先读 `remote.member.state.nature` 的 `disaster`／`warning`，摘要天气块过期后按 RECORD-04 的同一做法用摘要携带的 `nature` 种子在本地推导，不新增消息。只有当前灾害进入表现节点，预警只进 HUD。 |
| `tests/disaster_presentation_test.gd` | 新增 55 项无头检查，只依赖纯模块与 `NatureState`，不加载美术。 |
| `tests/weather_atmosphere_test.gd` | 由 42 项扩展到 57 项：暴雨提示不改变天气种类、只提高雨量；重复、未知与清除均幂等；干旱恢复普通雨量。 |
| `tests/single_player_nature_scene_test.gd` | 由 35 项扩展到 42 项：真实单机场景的 `DisasterInfo` 位置、输入穿透、未加载／空文案隐藏、实际视图一致。 |
| `docs/2.0/milestones/M6/PLAN.md` | M6-04 记录行补本切片链接。 |

未改动 `Game/farm/` 的结算与存档规则、`Game/scenes/environment/` 的动物作息与导航、网络协议、世界包、`V27Importer.KNOWN_FARM_KEYS`、ADR-009 的玩法结论与美术资源。

## 文案与表现规则

- **文案**：当前灾害优先，形如「灾害：干旱（持续至 01-15 14:00 UTC）」「灾害：暴雨（持续至 01-15 14:00 UTC）」；只有预警时形如「预警：暴雨 约 2 小时后」。时间只用 UTC，由 `Time.get_datetime_dict_from_unix_time()` 转换，不读本地时区。`now_utc` 无效、种类未知、起止时间格式错误、`ends_utc <= now_utc` 或预警已在当前或过去开始时都返回空行，因此 HUD 不会显示已过期摘要。
- **提前量**：优先用 `starts_utc - now_utc` 向上取整到小时，最小 1 小时；缺少开始时间时才用视图携带的 `lead_seconds`。这与 `HeadlessWorld.disaster_view()` 的字段一致。
- **当前与预警**：`disaster_view()` 的当前事件覆盖现在；预警只覆盖紧邻的下一个块。同一条 HUD 行只显示当前事件，避免两行互相遮挡；`describe()` 对预警仍返回种类并置 `warning=true`，`main.gd` 只用它更新文案，不把预警送到表现节点。
- **场景提示**：暴雨把同一雨发射器的粒子数从 700 提到 `STORM_PARTICLES=900`，仍复用单个 `GPUParticles3D`、单材质与现成包围盒；干旱在非雨天气把太阳轻微抬暖、远景压干。两者都不改变天气种类、湿度、生长、动物作息或导航；雨天下不叠加干旱暖色，晴天不假装暴雨，避免与现有天气情绪冲突。事件结束只需再次调用 `set_disaster("")`，下一次 `_apply_clock()` 从季节与天气重新组合，属于纯可逆调整。
- **共享世界**：摘要仍是权威；摘要的天气块仍覆盖 `now` 时直接使用其中的 `disaster`／`warning`。跨过块尾后，用摘要同时携带的 `nature` 种子快照本地推导，和 `_weather_view()` 的过期处理一致，最多等到下一次 30 秒校正，不额外请求。

## 实际验证

命令在仓库根目录执行，引擎为 `/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot`，单测超时 300 秒，场景测试使用 `--audio-driver Dummy`。

```
DISASTER_PRESENTATION_TEST checks=55 failures=0
WEATHER_ATMOSPHERE_TEST checks=57 failures=0
SINGLE_PLAYER_NATURE_TEST checks=42 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/single-player-nature-230636
M4_CLIENT_SCENE_TEST checks=29 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-client-scene-268995
```

上述场景夹具按自身约定写到 `.local/verification/single-player-nature-<时间戳>` 与 `.local/verification/m4-client-scene-<时间戳>`；本次已把两份最终产物移动到任务目录 `.local/verification/disaster-presentation-58481/single-player-nature/` 与 `.../m4-client-scene/`，原路径不再保留。纯规则与天气夹具不写文件。

`disaster_presentation_test` 覆盖：无事件、当前干旱／暴雨、缺少结束时间、当前优先于预警、预警提前量（按开始时间、按 `lead_seconds`、不足 1 小时、缺少提前量）、开始时间覆盖旧的 `lead_seconds`、已过期当前事件、已过期预警、把未来事件误当当前、未知种类、非法时间字符串、非字典输入、无效 `now`、同输入同输出且不改动输入字典、视觉情绪的晴／雨跳过规则与夜晚有界、同一视觉输入重复输出一致，以及用真实 `NatureState` 事件核对标签、表现种类、预警与精确结束时刻。

`weather_atmosphere_test` 新增覆盖：暴雨提示在晴天不启动雨、不以任何方式改变天气种类；雨天时同一发射器使用 900 粒子；重复与未知提示为 no-op；改为干旱恢复 700；清除提示后为空。

`single_player_nature_scene_test` 新增覆盖：`DisasterInfo` 在 top 124、位于天气行下方且不接收鼠标；空文案与未加载时隐藏；加载后显示真实文案；`_sync_weather()` 后的可见性与 `_disaster_view()` 推导一致。

`m4_client_scene_test` 使用真实权威进程与真实 `main.tscn`，29 项既有共享世界检查全部通过，说明新增的灾害读取、HUD 行与视觉提示没有破坏联机、收获或社交路径。该夹具不控制天气或灾害，因此**不能**据此宣称共享世界画面中实际出现过灾害 HUD 或暴雨密度变化。

本地 `--check-only` 已对全部改动脚本与两个夹具通过。测试退出时仍有既有的 `DummyShaderE`／`ObjectDB` 泄漏告警，不影响断言结果；未据此宣称资源零泄漏。

规则工作流双平台证据（run `43677519694`，提交 `2e9a1f5`，干净检出）：

```text
macOS   weather_atmosphere_test WEATHER_ATMOSPHERE_TEST checks=57 failures=0
macOS   disaster_presentation_test DISASTER_PRESENTATION_TEST checks=55 failures=0
Windows weather_atmosphere_test WEATHER_ATMOSPHERE_TEST checks=57 failures=0
Windows disaster_presentation_test DISASTER_PRESENTATION_TEST checks=55 failures=0
```

`single_player_nature_scene_test` 在两个平台的干净检出中都按 `skipped=no-art` 跳过（场景预载 LFS 美术），因此 HUD 行与场景显隐只在本地 macOS 场景环境中验证。

## 停用灾害开关（M6-04 追加）

`nature.json` 增加可选 `disaster_mode`：缺省 `gentle` 时不写入字段，旧两键文档原样读取；`off` 只让此后派生的 `disaster_at()` 为空、`next_disaster_at()` 为 -1，天气序列、已结算湿度、生长与库存不回溯。`HeadlessWorld.set_disaster_mode()` 先持久化成功再改内存；单机在设置「世界」页切换，失败时保留原模式并提示；共享世界客户端从摘要读取模式、菜单只读，网络 RPC 与房主触发未接入。详见 [ADR-009 决定 7](../../decisions/ADR-009-disasters.md)。

```
DISASTER_TOGGLE_TEST checks=79 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/disaster-toggle-267183
NATURE_STATE_TEST checks=149 failures=0
NATURE_INTEGRATION_TEST checks=856 failures=0 fingerprint=4d38cdfcdafe3e88c4854f846835eac23d6c6e6fd6245548707fe345d876c5cf
DISASTER_TEST checks=247 failures=0
SETTINGS_TEST checks=53 failures=0
GAME_MENU_TEST checks=87 failures=0
SINGLE_PLAYER_NATURE_TEST checks=42 failures=0
```

`disaster_toggle_test` 覆盖：默认与旧形状、`off` 快照往返、天气不受开关影响、120 天无任何灾害事件、`next_disaster_at` 恒为 -1、同一世界在关闭与“从未有灾害”下的最终快照逐字节一致、成熟与收获照常、权威 `set_disaster_mode()` 的持久化与非法值拒绝。

规则工作流双平台证据（run `43679013546`，提交 `ec88609`，干净检出）：

```text
macOS   disaster_toggle_test DISASTER_TOGGLE_TEST checks=79 failures=0
Windows disaster_toggle_test DISASTER_TOGGLE_TEST checks=79 failures=0
```

开关实现提交为 `a52e5e1`，workflow 登记与 M7-04 同批进入 `ec88609`，因此 CI 证据对应后者；两平台都实际执行该夹具，而非无美术跳过。

## 未覆盖

- 未取得实机截图，未对视口尺寸、夜间可读性、雨量加密后的观感、干旱色偏做美术验收；本记录只证明节点参数、纯文案、显隐条件和场景回归。
- 共享世界摘要过期窗口最多约 30 秒，未单独做网络分区或长时断网验证；逻辑与 RECORD-04 的天气过期路径一致。
- 预警按现有规则只覆盖紧邻的下一个 6 小时块；更远预警、按地块灾害范围、声音与 NPC 反应均未实现。风险模式此后已由 [RECORD-08](RECORD-08-disaster-risk.md) 补上，但本文的表现与 HUD 文案未随之区分模式。
- `m4_client_scene_test` 不控制灾害；共享世界 HUD 的“实际出现灾害”仍缺一条可控夹具。
- 场景夹具（`single_player_nature_scene_test`、`m4_client_scene_test`）只在本地 macOS 美术环境运行，Windows 实机画面未验证；纯规则部分已双平台通过。
- 停用开关只在单机菜单与权威 API 生效，共享世界没有网络命令或房主菜单入口；客户端的只读展示依赖摘要字段，未做断线或旧摘要兼容测试。停用开关不改变已发生湿度。风险模式与另外两种模式共用同一菜单项，见 [RECORD-08](RECORD-08-disaster-risk.md)。

## 相关裁决

- [ADR-009 温和模式的灾害与预警](../../decisions/ADR-009-disasters.md)
- [RECORD-03 灾害与恢复](RECORD-03-disasters.md)
- [RECORD-04 天气表现与过度阴天](RECORD-04-weather-presentation.md)
