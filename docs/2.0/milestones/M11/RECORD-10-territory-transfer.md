# M11-01 · 地籍转让与通行判定（权威切片）

执行日期：2026-11-16。状态：切片完成，不表示 M11-01 或 M11 验收完成。前置：[M11 地籍规则](RECORD-01-cadastre.md)、[地籍接入权威](RECORD-02-cadastre-authority.md)、[地籍客户端入口](RECORD-06-cadastre-client.md)、[ADR-023](../../decisions/ADR-023-land-cadastre.md)、[ADR-028](../../decisions/ADR-028-build-land-authority.md)。

## 问题

M11-01 规则早已有 `transfer`，权威也有 `WorldHost.territory_for_member()` 的 `transfer` 动作，但两处都没有回答“接收人是否属于这个世界”：任何合法格式的玩家 id 都能接住一块地。通行判定只有纯函数 `may_trespass`，没有权威入口，也没有把公共项目绑定地块算作可通行。本切片只补这两条规则边界，不做定价、托管、租赁或界面。

## 决定与实现

### 1. 转让要求接收人是世界已开户成员

- 规则层 `TerritoryState.transfer(..., members = null)` 新增可选只读成员列表。传入列表时，接收人不在列表中返回 `unknown_member`；省略时保持首版行为（只校验玩家 id 格式），不影响既有调用方。
- 权威层 `HeadlessWorld.territory_members()` 从经济快照派生“已开户成员”：`accounts` 中存在、`granted=true`、且不是 `@world`、`@merchant`、`org_` 账户或居民 id。名单按 id 排序，不写入地籍文档。
- 选择依据：任务要求“目标必须是世界成员”，并明确写成“已开户成员”。开户（`granted=true`）是耐久、可重启恢复的世界事实；成员连接本身只在内存里，不能作为长期名单。
- `transfer_territory()` 在规则调用时传入该名单，因此规则层与权威层同时校验；无主地块、非权利人、转给自己仍分别返回 `not_owned`、`not_owner`、`same_owner`。

### 2. 通行判定：纯规则 `can_pass` + 权威只读入口

- `TerritoryState.can_pass(state, parcel_id, actor, passable_parcels = [])`：
  - 本人地块可通行（`claimed` 且 `owner == actor`）；
  - 无主地块可通行；
  - `public` 地块可通行；
  - 他人私有地块默认不可通行；
  - `passable_parcels` 中的 id 对所有人可通行。该列表由调用方派生，规则不读取其它文档、不改地籍、也不授予建造权。
- `may_trespass()` 保留为 `can_pass()` 的无外部列表别名，ADR-023 首版权限表与既有测试语义不变。
- 地籍文档没有“公共通路”字段。本切片检查了公共项目文档：`PublicWorks` 的 `parcel_id` 已是既有字段，`built` 状态是权威事实。`HeadlessWorld.public_works_passable_parcels()` 只读地返回所有 `status == built` 且绑定非空地块的 id；不新增字段、不改公共项目文档。未建成的项目不贡献通行权。
- 权威入口 `HeadlessWorld.can_pass_territory(parcel_id, actor)` 返回 `{ok, reason, parcel_id, passable}`：未知地块 `unknown_parcel`、非法 actor `invalid_player`。
- `WorldHost.territory_for_member()` 新增只读动作 `can_pass`，与 `state` 一样对成员、访客开放；操作者来自连接。RPC 9/10 的编号与既有六键答复形状不变，`can_pass` 只在答复中多一个 `passable` 键。

### 3. 建造门禁继续只认 `owner`

ADR-028 的 `build_gate` 未改。转让只改土地行，所以转让后新权利人可建造、原权利人被拒；通行判定不参与建造授权（测试验证“公共项目地块可通行但不可建造”）。地籍转让仍不移动、拆除或改写地上建筑（ADR-023）。

### 4. 幂等、持久化与错误文案

- 同一命令 id 幂等：命令窗口内回放首次结果；窗口淘汰后由地块 `claim_id` 耐久守卫识别重放，重启后仍 `duplicate` 并复用原土地时间。
- 成功转让写 `territory.json`（pending + 回读 + rename），失败或重放不写文件；`sequence` 每次成功只加一。
- 新增拒绝原因 `unknown_member`，权威文案“接收人还不是这个世界已开户的成员。”；`invalid_player`、`unknown_parcel` 复用既有通用文案。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/world/territory_state.gd` | `transfer` 增加可选成员列表与 `unknown_member`；新增 `can_pass()`，`may_trespass()` 改为别名 |
| `Game/world/headless_world.gd` | `territory_members()`、`public_works_passable_parcels()`、`can_pass_territory()`；转让传入成员列表 |
| `Game/world/world_host.gd` | `territory_for_member()` 的只读 `can_pass` 动作；答复可选 `passable`；`unknown_member` 文案 |
| `tests/territory_transfer_test.gd` | 新增切片夹具 |
| `tests/territory_authority_test.gd` | 转让用例先开耐久账户再转让 |
| `docs/2.0/milestones/M11/RECORD-10-territory-transfer.md` | 本记录 |

未改 `.github/`、PLAN、`rules/`、`player-guide.md`、地籍存储格式、RPC 编号、`PROTOCOL_VERSION`。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
for t in territory_transfer_test territory_test territory_authority_test \
         territory_build_gate_test territory_client_test chain_integration_test \
         public_works_authority_test; do
  perl -e 'alarm shift; exec @ARGV' 600 "$GODOT" --headless --path Game \
    --script "$PWD/tests/$t.gd"
done
```

原始末行：

```text
TERRITORY_TRANSFER_TEST checks=154 failures=0
TERRITORY_TEST checks=159 failures=0
TERRITORY_AUTHORITY_TEST checks=72 failures=0
TERRITORY_BUILD_GATE_TEST checks=79 failures=0
TERRITORY_CLIENT_TEST checks=30 failures=0
CHAIN_INTEGRATION_TEST checks=509 failures=0
PUBLIC_WORKS_AUTHORITY_TEST checks=177 failures=0
```

`territory_transfer_test.gd` 覆盖：

| 用例 | 检查 |
|---|---|
| 规则转让 | 未知地块、无主、非权利人、转给自己、非成员分别拒绝且不改 owner；成功转让写入新 owner、时间和 command id；文档仍有效；同 id 回放返回首次结果且文档不变；同 id 换时间 `command_conflict`；省略成员列表保持首版行为 |
| 规则通行 | 本人、无主、公共、他人私有四种情况；公共项目列表只放行对应 id；`may_trespass` 无外部列表语义不变；未知地块与非法 actor 拒绝 |
| 权威转让 | 成员名单只来自 `granted` 账户；连接身份操作；无主/转给自己/非成员/访客分别返回 `not_owned`/`same_owner`/`unknown_member`/`forbidden` 且带中文文案；成功转让立即落盘；回放不增命令；原权利人再转让 `not_owner` |
| 建造门禁 | 转让后原权利人 `not_parcel_owner`、新权利人建造成功；独立目录验证转让前后同一槽位的准入翻转 |
| 重启持久化 | owner、`claim_id`、成员名单跨重启保留；同 id 回放仍 `duplicate` 并复用原时间；重启后可反向转回 |
| 公共项目通行 | 真实 `public_works.json` sidecar 中 `built` 项目绑定地块对他人可通行；未绑定的私有地块仍不可通行；无主仍可通行；通行不授予建造；具名访客可查询，无玩家 id 成员 `invalid_player` |
| 命令日志与摘要 | 70 次交替 claim/release 后 `sequence=70`、命令窗口正好 64 条；`territory_display()` 报告新 owner，且不下发 `claim_id` |

## 未覆盖

- **定价与托管**：转让没有价格、支付、托管或双方确认；本切片明确不涉及现金或租赁价格，规则只搬权属。将来接入价格时必须决定谁付款、何时结算、失败如何回滚。
- **租赁**：没有租约、期限、租金、地役权或“唯一公共通路连通性”判定；`can_pass` 只回答单块地，不计算从 A 到 B 是否存在可通路径。
- **地图通行路径**：地籍矩形尚未与真实地图、字段或建筑槽位坐标对齐，公共项目只按登记的 `parcel_id` 放行，渲染与寻路都不存在。
- **UI**：没有转让选人界面、确认框、地图地块高亮或通行提示；客户端协议可构造 `transfer`/`can_pass`，但面板不提供入口。
- **其它成员定义**：名单只认已开户账户。仅加入过世界但从未开户的玩家不能被转让接收；同一安装的多个别名若都已开户会各自出现，未与 ADR-029 的赠款别名规则合并。
- **转让后的地主≠房主**：沿用 ADR-023/ADR-028 的治理缺口，转让不搬房，新权利人可在旧建筑旁建造（槽位已被占用时由既有建筑规则拒绝），但没有存量错配裁决。
- **窗口外语义**：`transfer` 在命令窗口淘汰后依赖地块 `claim_id`；若地块随后再次易主，旧命令 id 的重放会返回历史结果而不是“该地已不属于你”，与本模块既有 claim 重放一致。
- 只在本机 macOS 无头模式验证；未在 Windows 实机、CI 或真实局域网多机验证，也未做写失败注入。
