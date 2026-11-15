# M6-04 · 天气表现与过度阴天

状态：天气表现切片完成（2026-11-15），未验收。范围：把 `NatureState` 已暴露的当前天气接到世界可见表现——程序化降雨与昼夜光照的阴/雨情绪；不改玩法、存档、网络消息或镜头，不新增美术文件。居民作息与灾害不在本切片。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/presentation/weather_atmosphere.gd` | 新增。自建 `GPUParticles3D` + `ParticleProcessMaterial` + 细长 `QuadMesh` 雨线；发射盒水平跟随相机、以院落地面为底，显式设置 `visibility_aabb`；粒子数固定 700（≤900），`fixed_fps=30`，非雨天气 `emitting=false`、`visible=false` 并停止逐帧更新；不重建节点。`weather_changed(kind)` 作为阴天/降雨的响应钩子，由场景转给 `day_night.set_weather()`。 |
| `Game/atmosphere/day_night.gd` | 新增单一天气情绪输入 `set_weather(kind)`（`clear`/`cloudy`/`rain`，未知种类与重复种类均为空操作）及只读 `get_weather()`；`mood_for(kind)`／`apply_weather(values, kind)` 委托给不含美术依赖的 `weather_mood.gd`。`_apply_clock()` 在季节之后调用一次，不覆写时钟、季节或下一帧的采样。 |
| `Game/presentation/weather_mood.gd` | 新增纯数据模块：情绪表、`apply_weather()`、`accepts()`、中文标签与 HUD 文案。`day_night.gd` 会 preload 远景贴图、`farm_hud.gd` 会 preload 字体与主题，干净检出没有 LFS 美术时无法编译；把纯规则拆出来后，规则工作流才能在两平台无美术环境继续验证天气情绪与文案。 |
| `Game/scenes/main.gd` | 创建并配置 `WeatherAtmosphere`，把 `weather_changed` 接到 `atmosphere.set_weather()`。单机从 `nature_state.weather_at(clock.call())` 取当前块；共享世界先读权威摘要 `remote.member.state.nature` 的天气视图，摘要块过期后才用摘要同时携带的 `nature` 种子快照推导当前块，不额外发消息。`_sync_weather()` 在 `settle_farm()`、重连/摘要刷新后的 `_on_remote_state()` 和初始化后调用；种类相同时比较后跳过。 |
| `Game/scenes/farm_hud.gd` | 新增一行只读 `WeatherInfo`：「天气：晴／多云／雨」，自然视图带下次变化时间时追加「· 约 N 小时后变化」。无面板、图标或动画；`show_weather(text, loaded)` 在未加载或未知种类时隐藏。位置在 `EnvironmentInfo` 下方（top 92），避开底部农事控制。 |
| `tests/weather_atmosphere_test.gd` | 新增 42 项无头检查，见下。 |

未新增图片、着色器或依赖；世界包、农场文档、网络协议与镜头行为未改。

## 呈现与边界

- **一个天气所有者，两种消费**：天气仍由 `NatureState` 唯一拥有。单机直接调用 `weather_at()`；共享世界消费权威摘要中的 `nature` 视图。表现层只读，不调用农场结算，也不写任何存档或网络字段。
- **共享世界摘要过期**：权威摘要每 30 秒校正一次。若 `settle_farm` 的一秒节拍跨过摘要中天气块的 `end_utc`，实现用摘要随附的 `nature` 种子快照在本地推导当前块；这与服务端同一确定性规则一致，且不新增请求。下一次摘要仍会覆盖为权威视图。
- **昼夜情绪叠加而非替换**：`rain`/`cloudy` 只在白天按 `daylight` 比例压暗太阳、增加平坦天光、降低饱和并把天空/远景压成阴色；所有混合作用于 `sample_hour()` 与季节之后的值。夜间 `daylight=0`，太阳亮度不变，天光仅有界微调。`clear` 是恒等情绪，未知种类返回空情绪表。
- **雨线成本**：单发射器、单 draw pass、单材质；700 粒子、30 fps 固定步长、显式包围盒；发射盒每帧只更新位置，不创建数组或字典，不重建节点，不调用 `queue_redraw`。非雨时不发射且不逐帧移动。
- **HUD**：只增加一行文字。天气行在 `EnvironmentInfo` 下方、底部农事控制上方，未选择田格时仍单独显示；`_loaded=false` 时隐藏。文案由纯函数 `weather_text()` 产生，便于无场景测试。
- **未改变**：作物生长、湿度、收获、存档、世界包、RPC 字段、相机、分辨率与画质设置均未改；天气仍是纯表现输入。

## 实际验证

命令均在仓库根目录执行，引擎为 `/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot`。

```
WEATHER_ATMOSPHERE_TEST checks=42 failures=0
M4_CLIENT_SCENE_TEST checks=29 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-client-scene-554035
```

首轮 CI（run `43672841619`）在两平台都因 `weather_atmosphere_test` 报 `SCRIPT ERROR: Could not preload ... river-distance.png` 失败：测试直接 preload `day_night.gd` 与 `farm_hud.gd`，而干净检出没有 LFS 美术。复核把纯情绪与文案拆到 `weather_mood.gd` 并让测试只依赖该模块与雨节点后，本地无头 42 项通过；`day_night` 与 HUD 的两处委托由真实场景夹具 `m4_client_scene_test` 覆盖。

补充单机场景（验证 `nature_state.weather_at()` 分支与 HUD 接线未破坏既有湿度提示）：

```
SINGLE_PLAYER_NATURE_TEST checks=35 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/single-player-nature-443008
```

`weather_atmosphere_test` 覆盖：雨节点存在、粒子数 700 且 ≤900、`visibility_aabb` 非零、发射盒跟随相机水平位置；clear/cloudy 均不发射，rain 发射且复用同一节点；重复同类与未知种类均为空操作，`weather_changed` 每次真实变化只触发一次；正午 clear/cloudy/rain 的太阳能量严格递减且太阳色不同，阴天/降雨压暗并压平天空；未知种类不改变任何时钟值；午夜降雨的太阳/天光保持有界且有限；HUD 三种中文文案、未知种类为空、带下次变化时间与缺省时不追加。

`m4_client_scene_test` 使用真实权威进程与真实 `main.tscn`：共享世界场景在夹具当时的推导天气下正常完成 29 项既有检查，说明新增天气节点、摘要读取与 HUD 行没有破坏联机场景、收获或社交路径。该夹具不控制天气，因此**不能**据此宣称雨粒子在共享世界画面中出现。

结构性核验替代截图：本机屏幕捕获受 TCC 限制，未取得实机画面，因此**没有**用截图声称雨的密度、落速、透明度和阴天色偏达到美术验收。已验证的是节点/材质/粒子参数、天气种类的光照数值差异、HUD 文案与幂等行为；雨在真实镜头中的观感、与季节 mood 叠加后的最终色偏、不同画质下的成本均未截图或性能实测。

退出时引擎报告 `1 shaders of type ParticlesShaderRD were never freed`、`15 ObjectDB instances were leaked at exit` 等清理告警；测试与场景断言均通过，这些是场景直接 `quit()` 未逐节点释放时的退出期告警，不影响运行期结果，也未据此宣称资源零泄漏。

## 未覆盖

- 雨/阴天的实际画面质量（密度、雨线朝向、透明排序、与季节光照的最终色偏）未截图验收。
- 未做性能测量；只以单发射器、700 粒子上限、30 fps 固定步长和显式包围盒约束成本。
- 居民作息、灾害视觉、雷声/雨声、地面积水与云层变化未实现；真实天气服务仍未接入。
- 共享世界若在摘要间隔内跨过天气块，用摘要种子本地推导；该窗口最多约 30 秒，未单独做长时网络分区验证。
- 未新增场景级天气测试；`m4_client_scene_test` 只证明共享世界场景未因天气节点损坏，不检查雨粒子是否出现在画面中。

## 相关裁决

- [ADR-007 自然时间语义](../../decisions/ADR-007-nature-time.md)
- [ADR-008 区域降雨与地块湿度](../../decisions/ADR-008-rain-moisture.md)
