# M6-04 · 居民作息

状态：部分切片（2026-11-15），未验收。范围：让鸭子、鹅、鸡在下雨时于**各自已有的导航空间内**确定性地避雨；不改变玩法、存档、网络、HUD、美术或镜头。真正离开水面、走上院落的跨空间路线仍被现有导航空间的不连通阻断，见“仍受阻的跨空间行为”。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/scenes/environment/animal_weather.gd` | 新增。纯规则：`weather_goal()` 与水域、院落两组确定性候选项。只依赖布局数字与 `Space`，不加载美术、不使用随机数或时钟。 |
| `Game/scenes/environment/courtyard_animals.gd` | 新增 `set_weather(kind)`、`_shelter_from_rain()` 与避雨静止。`rain` 进入时对每只鸟最多重选一次目标；到达后原地休息（12–24 秒滚动），停留期间不再随机外出；离开 `rain` 时立即清掉避雨路线并回到普通作息。目标仍使用该鸟原有的 `entry.space`，并保留 `:551` 的水面／地面高度逻辑。鸡按稳定顺序轮换门廊檐下候选点，避免同格拥堵。 |
| `Game/scenes/main.gd` | `_sync_weather()` 在现有 `weather_atmosphere.set_weather(kind)` 旁调用 `$Environment/CourtyardAnimals.set_weather(kind)`。 |
| `tests/animal_weather_routine_test.gd` | 新增 30 项无头检查：正确空间、可达性、空目标、天气种类、顺序、阻挡、确定性、默认布局常量。 |
| `docs/2.0/milestones/M6/RECORD-05-resident-routines.md` | 本记录。 |

未新增网络消息、存档字段、HUD 行、导航线程、场景树重建或美术资源。

## 规则

- **天气种类**：只有 `rain` 改变目标。`clear`、`cloudy`、未知和空字符串均为空操作；重复的同类调用也是空操作。离开 `rain` 时，仍在去避雨途中的鸟立刻停下改回普通作息，不会继续飞向已经不需要的目标。
- **避雨停留**：到达避雨点后原地 `rest` 并滚动 12–24 秒计时；降雨期间下一次选点仍是休息，不会又游回雨中。雨停后恢复普通随机作息。停留计时使用现有 `_rng`，不新增逐帧成本。
- **水域鸟（duck／goose）**：候选项按顺序为桥下／桥背风水面，然后是现有带篷小船的背风水面。`weather_goal()` 用该鸟自己的 `entry.space.path(from, target)` 证明可达；返回空表示“保留当前目标”，绝不强制路线。默认布局里桥下共享带不可达，五只游泳鸟都落到第一个可达的篷船背风点 `(8.22, 5.2)`，符合“聚集到有顶水面”的目标。
- **鸡（hen）**：候选项为门廊檐下最近的可行走点（现有布局没有独立鸡舍节点，门廊是最近的现有带顶结构）。同样以 `entry.space.path()` 证明可达，不可达则保留当前目标。两只鸡按稳定的鸡序轮换同一组檐下候选点：`YardHen1` 取最近的 `(1.52, -1.2)`，`YardHen2` 取同一条檐线西侧的 `(-1.68, -1.2)`，避免排队挤在同一格；候选顺序仍由调用方确定。
- **不改空间与高度**：所有目标都留在鸟原来的 `water`／`yard` 空间，`courtyard_animals.gd:551` 的 `height` 选择不动，因此水域鸟仍在水面高度、鸡仍在地面高度，不会下沉或穿越地形。移动速度、步态、尾迹和水波逻辑未改。
- **转换成本**：天气变化时每只鸟最多一次目标替换（一次规则可达性检查＋一次取路）；没有逐帧分配、没有新的导航 worker、没有场景树重建。普通 `_advance()` 和 `_choose()` 路径不变。
- **确定性**：候选项来自布局锚点与桥体参数，按固定顺序尝试；鸡的轮换只依赖稳定的鸡序，不使用 `randf()`、帧时间或节点遍历顺序。相同输入重复构造得到相同序列。并列时由调用方给出的目标顺序决定。
- **共享目标与分离**：游泳鸟共享第一个可达的篷船背风点，现有局部避让与身体分离让它们聚集在目标附近而不是重叠；鸡则沿门廊檐线分散到不同候选点，避免两只鸡在同一格互相卡住。

### 目标常量与为何与美术无关

`Game/scenes/environment/animal_weather.gd` 只使用以下布局数字：

- `BRIDGE_LEE_T = [0.50, 0.62, 0.38, 0.74, 0.26, 0.86]`：沿 `island_construction.gd` 的 `bridge_points()` 连线取样。
- `BRIDGE_LEE_LATERAL = [0.0, -0.45, 0.45]`：桥面 1.2 m 宽度内的横向偏移。
- `BOAT_LEE_OFFSETS = [(-0.75,0.95), (0,1.2), (-1.2,0.45), (1.2,0.2), (-1.2,-0.45), (0,-1.2)]`：以 `plan.anchors.boat` 为原点的固定米制偏移。
- `YARD_SHELTER_OFFSETS = [(0,0), (-1,0), (1,0), (0,0.7), (0,-0.7), (-1,0.7), (1,-0.7)]`：以 `plan.anchors.veranda` 为原点的固定米制偏移。

这些数字全部来自 `courtyard_plan.gd` 的布局锚点和 `island_construction.gd` 的桥体参数，没有读取 GLB、贴图、材质或渲染节点。无头测试只用 `courtyard_plan.gd` 与一个空的 `AnimalSpace` 就能构造和比较它们。

## 实际验证

命令均在仓库根目录执行，引擎为 `/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot`。

```
ANIMAL_WEATHER_ROUTINE_TEST checks=30 failures=0
M4_CLIENT_SCENE_TEST checks=29 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-client-scene-469745
```

规则工作流双平台证据（run `43676370481`，提交 `2858b21`，干净检出无美术）：`rules (macos-latest)` 与 `rules (windows-latest)` 均 success；`animal_weather_routine_test` 不依赖贴图、字体、场景或 GLB。

复核命令（`GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot`）：

```
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game --script "$PWD/tests/animal_weather_routine_test.gd"
perl -e 'alarm shift; exec @ARGV' 420 "$GODOT" --path Game --audio-driver Dummy --script "$PWD/tests/m4_client_scene_test.gd"
```

`animal_weather_routine_test` 覆盖：duck／goose 返回 `water`、hen 返回 `yard`、未知物种返回空；`clear`／`cloudy`／未知／空字符串返回空；阻挡空间返回空；按顺序跳过不可达目标并选择第一个可达目标；两次调用结果相同；所选点确实由 `space.path()` 到达且路径终点在目标一格内；默认布局的桥下、篷船背风与门廊候选项都能从布局数字构造，重复构造序列一致。

### 真实场景探针

下面的只读探针（`.local/verification/probe_weather_apply.gd`）使用真实 `main.tscn`、隔离存档和默认天气（当前时段为 `rain`），在 `_sync_weather()` 已运行后检查：

```
APPLY initial_kind=rain
APPLY water_targets=[(8.059999,-0.08), ..., (8.219999,5.2), (8.859999,5.52), (7.74,4.88), (9.019999,2.96)]
APPLY yard_targets=[(1.52,-1.2), (-1.68,-1.2), (1.68,-1.2)]
APPLY LakeDuck1 kind=duck first_goal={"space":"water","point":(8.219999,5.2)} route_end=(8.219999,5.2) state=swim in_space=true
APPLY LakeGoose2 kind=goose first_goal={"space":"water","point":(8.219999,5.2)} route_end=(8.219999,5.2) state=swim in_space=true
APPLY YardHen1 kind=hen first_goal={"space":"yard","point":(1.52,-1.2)} route_end=(1.52,-1.2) state=walk in_space=true
APPLY YardHen2 kind=hen first_goal={"space":"yard","point":(1.52,-1.2)} route_end=(-1.68,-1.2) state=walk in_space=true
APPLY_FAILURES=0
```

- 默认布局里桥下共享带仍不可达，所以五只游泳鸟都落到第一个可达目标：带篷小船背风的 `(8.22, 5.2)`；两只鸡分别到门廊前的 `(1.52, -1.2)` 与同一条檐线西侧的 `(-1.68, -1.2)`。
- 重复 `rain` 为空操作；`clear`、`unknown`、空字符串不重选目标；两秒模拟后所有鸟仍在各自 `space.contains()` 内，姿态有限。
- 避雨停留与雨停恢复由真实场景探针（`.local/probe_shelter_stuck.gd`，隔离存档、强制 `clear`→`rain`）检查：六分钟模拟后五只游泳鸟都停在篷船背风点附近 `(6.9–10.0, 4.9–6.5)`，鸡在门廊檐线；途中出现 18–28 次卡角重寻路，但没有一只长期停在原地（`recoveries` 只说明重寻路次数，不是失败）。这是观感风险，未做画面验收。
- `tests/animal_behavior_test.gd` 原本读取真实时钟天气；当前时段是 `rain`，新作息会把全体居民停在避雨点，原本要观察的 `hen/peck`、`duck/probe` 等状态就不再出现。夹具现在先停止 `SettlementTimer` 并把天气固定为 `clear`，再测普通移动；结果是 `ANIMAL_BEHAVIOR_PASS`，各鸟 recovery 0–8，没有新增失败。该测试不是本切片的验收门槛，但必须保持与天气无关。

`m4_client_scene_test` 不控制天气，因此只证明新增节点、`set_weather()` 接线与天气同步没有破坏共享世界场景；不能据此宣称雨中的实际画面已经验收。

## 仍受阻的跨空间行为

真正的“游泳鸟离开水面、走上院落”仍不可行，本次不改导航、桥、地形或高度。依据：

- `courtyard_animals.gd:136` 的水域空间把岸线／建筑足迹作为障碍；`:138` 的院落空间只包含 `bridge_passage.gd:21` 的陆地与桥面；`:229` 按物种固定分配两个空间。
- 真实场景探针：水域与院落只在桥面附近有 38 个共享采样点；五只游泳鸟到该点的水域寻路长度全部为 0，而同一水域其他开放水面点可正常寻路（原始 A* 28–143 点）。桥面共享带高于水面且不是岸坡。
- 鸭子最近的可走陆地点 `(-6.96,1.52)` 与房屋后侧 `(0.72,-7.44)` 在 `yard` 中到门廊均无路径；这些岸段属于孤立组件。
- 即使有路线，`courtyard_animals.gd:551` 对所有非鸡物种固定使用水面高度并保留水面尾迹，切换空间会让鸟沉到地面以下。

解除这一阻塞仍是三选一，需要产品决定：

1. 在现有导航中补一条真实的岸线通行带，让水域与院落空间合法重叠，并同时补陆上姿态／尾迹处理。
2. 明确允许游泳鸟只在有顶棚的水面避雨（当前切片已按此方向落在带篷小船背风处）。
3. 只保留鸡的作息，接受游泳鸟在雨中的现有行为。

## 未覆盖

- 没有截图；雨的密度、鸟在篷船旁的实际构图、遮蔽感与鸡在门廊前的观感未做画面验收。
- 没有长时间实时运行；只有规则测试、真实场景即时目标检查、两秒运动检查与六分钟人工步进模拟。
- 避雨途中会出现多次卡角重寻路（六分钟模拟 0–28 次，取决于起点），最终都能到达；没有优化转向半径或路线，也没有做真实玩家观感验收。
- 没有天气声音；本切片不涉及音频。
- 默认布局的桥下目标不可达，当前真实场景使用的是带篷小船背风目标；桥下常量只在未来可达布局中生效。
- 自定义鸡／鸭活动区域若不含候选项，`weather_goal()` 会返回空并保留当前目标；未逐一验证所有自定义区域。
- 游泳鸟共享篷船背风点、鸡沿门廊檐线分散，二者都依赖现有分离逻辑；未做密集鸟群的主观观感验收。
- 未运行 Windows 场景或性能测量。

## 相关记录

- [RECORD-04 天气表现](RECORD-04-weather-presentation.md)
- [ADR-007 自然时间语义](../../decisions/ADR-007-nature-time.md)
