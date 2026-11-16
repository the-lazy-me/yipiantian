# M8-04a · 公共项目接入世界权威（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M8-04a 或 M8-04 验收完成。前置：[M8 PLAN](PLAN.md)、[RECORD-04 · 公共基金](RECORD-04-public-funds.md)、[RECORD-06 · 公共项目与基金规则](RECORD-06-public-fund-implementation.md)、[RECORD-07 · 公共基金接入世界权威](RECORD-07-public-fund-authority.md)。

## 问题

公共项目（村口广场、公井、石板路）已有纯规则：固定成本、承诺/退回、足额后建成，但世界权威里没有项目文档，也没有把“建成”接到真实基金支出。玩家承诺只是记账承诺，不是现金托管；建成时必须由组织基金真实付款，且同一命令重试不能二次支出。

## 边界

- 新增 `Game/world/public_works_store.gd` 与 `tests/public_works_authority_test.gd`。
- 修改 `Game/world/headless_world.gd`（`public_works_view`、`execute_public_works`、提交与重放）、`Game/world/world_host.gd`（RPC 21/22、权限）、`Game/world/world_member.gd` 与 `Game/world/world_client.gd`（客户端入口与预算解码）。
- 未修改 `Game/world/public_works.gd` 纯规则、基金规则、农场存档格式、`Game/ui/*`、场景与协议版本。

## 持久化

`public_works.json` 信封与其它 world 级 sidecar 相同：

```text
{version: 1, state: {projects: {<project_id>: <row>}}}
```

- 缺失：合法的空项目表。
- 损坏 / 版本不支持：权威拒绝启动，绝不用空表覆盖已有项目、承诺与建成时间。
- 64 KiB 上限（`PublicWorksStore`）；pending 写入、回读逐字节校验、rename。

项目行：`kind`、`parcel_id`、`funded`、`pledged`、`status`（`unbuilt`/`funded`/`built`）、`built_utc`。承诺不是现金；`pledged` 与 `funded` 只表示承诺额与固定成本覆盖额。

## 动作

`HeadlessWorld.execute_public_works(action, actor, args, command_id)`：

| action | 参数 | 行为 |
|---|---|---|
| `state` | 无 | 返回只读视图 |
| `open` | `project_id`、`kind`、`parcel_id` | 按固定目录登记项目，状态 `unbuilt` |
| `pledge` | `project_id`、`amount` | 增加承诺；覆盖固定成本后 `funded` |
| `release` | `project_id`、`amount` | 退回承诺，不得超过已承诺额 |
| `build` | `project_id`、`fund_id` | 足额后由该基金真实支出固定成本并标记建成 |

- 操作者恒为连接层解析的玩家；参数里的 actor/owner 不参与授权。
- 同 command id 同载荷即时重放返回首次结果并标记 `duplicate`；同 id 换参数返回 `command_conflict`。
- 成功命令与项目状态同一次原子保存写进项目文档的可选 `commands` 表（payload 的 SHA-256 与五个稳定结果字段，最多 64 条 FIFO），重启后同一命令 id 仍返回首次结果；进程内内存窗口只用于省一次读表。

## build 的跨文档顺序

1. 检查项目存在、状态为 `unbuilt`/`funded`；未足额直接 `underfunded`，不定位基金。
2. 用 `fund_id` 找到基金与组织账户 `org_<org_id>`。
3. 调用 `execute_fund("spend", actor, {...}, "pw_spend_<id>")`：keeper/组织职位/余额由基金权威复核，真实现金从组织账户转入 `@world`（农场落盘），基金文档写入 `fund_spend_pw_spend_<id>` 分录与 history。
4. 用该账本分录的 `at_utc` 作为同一权威时刻调用 `PublicWorks.mark_built`。
5. 保存项目文档。项目保存失败返回 `save_public_works_<kind>`，此时现金已动；重试会经基金结果或账本标记判重，只补项目，不二次转账。

跨重启恢复：

- 项目已建成 + 本命令账本分录金额匹配 + 基金 history 有同项目同成本 → `duplicate`。
- 金额或项目对不上 → `command_conflict`。
- 无本命令分录但项目已建成 → `already_built`。

## 视图与 RPC

`public_works_view()`：

```text
{projects[{project_id, kind, parcel_id, funded, pledged, status, built_utc}]}
```

- 按 `project_id` 升序；相同项目集合产生逐字节相同的载荷；不下发命令记录。
- 读取（`state`）对成员开放，包括访客与匿名成员；写入要求 `MEMBER`、非只读、具名玩家。
- RPC 21 `public_works_request(payload)`、22 `_public_works_reply(request_id, payload)`；请求与答复共用 48 KiB `WorldPayload.WIRE_BUDGET_BYTES`，超限换成可见的 `payload_too_large`；与其它权威写入共用命令令牌桶。
- `WireMember` 频道 22 先 `Payload.decode`；客户端新增 `request_public_works()` 与 `public_works_result` 信号。

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/public_works_authority_test.gd"
```

原始末行：

```text
PUBLIC_WORKS_AUTHORITY_TEST checks=238 failures=0
```

回归：`PUBLIC_FUND_AUTHORITY_TEST 211/0`、`FUND_NETWORK_TEST 99/0`、`CONFLICT_AUTHORITY_TEST 276/0`、`PARTICIPATION_AUTHORITY_TEST 121/0`。

覆盖：

| 要求 | 覆盖 |
|---|---|
| 缺失=空表、写盘往返、损坏/版本拒绝且不覆盖、64 KiB | 是 |
| open/pledge/release 拒绝与成功、写时复制 | 是 |
| 内存幂等 duplicate、换参 command_conflict | 是 |
| underfunded / not_keeper / role_forbidden / insufficient_funds | 是 |
| build 现金、`total_cash==issued`、spent/history、built_utc/status、落盘 | 是 |
| 同 id 重放现金/项目/基金字节不变 | 是 |
| 同 id 换项目/金额 conflict（含重启后同成本异项目） | 是 |
| 重启后项目与 history 仍在、只补项目不二次支出 | 是 |
| 付款后项目写盘失败、客户端换新命令 id 重试：任意基金 history 已有同项目同金额支出时只补项目状态，不再扣款 | 是 |
| 跨重启同 id open/pledge/release/build 重放 duplicate 且金额/项目/现金不变，换参 conflict | 是 |
| 视图排序与字段白名单 | 是 |
| WorldHost 访客只读、匿名 no_player、非成员、read_only | 是 |

## 未覆盖

- 真实网络路径：见 [RECORD-11 · 公共项目真实网络测试](RECORD-11-public-works-network.md)。
- 极端崩溃组合“基金文档也未保存且同一命令 id 换成同成本另一项目”：账本分录只含金额，重试补写时会按重试项目写 history；正常成功路径与“仅项目保存失败”路径均能识别项目不一致。
- 资金不足与职位变化的并发竞争、两个客户端同时 build 同一项目。
- 公共项目 UI、地图上选择地块、建成后的视觉建筑不在本切片内。

## 增补：持久命令表（2026-11-16）

原切片的重放窗口只在内存，重启后同一命令 id 会重新执行：pledge 再加一次承诺、
release 再退一次、open 再登记一次。现在项目文档新增可选顶层 `commands`：

- 每条成功命令记录 `{payload: sha256(动作|操作者|参数 JSON), result: {ok, reason,
  action, project_id, duplicate}}`；结果与项目状态在同一次 `save_state()` 里原子
  落盘，保存失败时两者都不生效。
- 读取时先查 `commands`：同载荷返回首次结果并置 `duplicate=true`，不同载荷返回
  `command_conflict`；因此 build 的账本标记查重之前就能识别跨重启重放，不依赖
  512 条环形账本是否仍保留分录。
- 表最多 64 条，按插入顺序淘汰最旧记录。严格校验拒绝非字典表、超过上限、命令
  id 含控制字符或超长、payload 不是 64 位小写十六进制、结果键集不符、动作未知或
  项目 id 非法；`commands` 缺失时文档仍合法，旧文档无需迁移。
- 失败命令不记录，重试仍会执行规则并得到当前拒绝原因。

测试 `PUBLIC_WORKS_AUTHORITY_TEST` 从 198 增至 238 项：命令表纯规则的记录/重放/
换参冲突/上限淘汰与五类篡改拒绝；权威侧重启后同 id open、pledge、release 返回
结果而文档逐字节不变、承诺额不重复累计，换项目或换金额返回 `command_conflict`；
建成后重启重放同一 build 返回 `duplicate` 且现金不变。回归
`PUBLIC_WORKS_NETWORK_TEST 107/0`、`PUBLIC_WORKS_PANEL_TEST 80/0`、
`PUBLIC_WORKS_VIEW_TEST 25/0`、`CHAIN_CONFLICT_INTEGRATION_TEST 512/0`、
`WORLD_TRANSFER_SIDECARS_TEST 153/0`、`HEADLESS_WORLD_RUNTIME_TEST 83/0`、
`FONT_COVERAGE_TEST 1272/0 missing=0`。

## 关联

- 规则：[RECORD-06 · 公共项目与基金规则](RECORD-06-public-fund-implementation.md)。
- 基金权威：[RECORD-07 · 公共基金接入世界权威](RECORD-07-public-fund-authority.md)；网络：[RECORD-09 · 公共基金真实网络测试](RECORD-09-public-fund-network.md)。
- 阶段计划：[M8 PLAN](PLAN.md)。
