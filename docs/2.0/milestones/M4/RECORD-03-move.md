# M4-04 · 世界搬迁（停写与交接）

执行日期：2026-11-15。状态：切片完成，不表示 M4 或 M4-04 验收完成。前置：[M4-03 同步与重连](RECORD-02-sync.md)、[ADR-004](../../decisions/ADR-004-transport.md)。

## 实现

搬迁按“先停写、再搬、后交接”三步落地，每一步都有可执行的拒绝路径：

- **停写边界在命令入口**：`WorldHost.read_only` 为真时，`execute_for_member()` 直接返回 `{"ok": false, "reason": "read_only"}`，并带回当前 `sequence`。拒绝放在命令入口而不是新连接入口，因为已经连上的成员不会因拒绝新连接而停止提交；只关大门等于没关。
- **身份延续靠签名描述符**：`Game/world/world_identity.gd` 生成迁移描述符，用邀请时已经固定的世界密钥签名，内容绑定 `world_id`、新运行代次、承接序号、状态摘要（`content_digest`）与新地址。地址也在签名内，攻击者无法把客户端指向自己的服务器。
- **代次单调**：`verify()` 要求新代次必须大于客户端已接受的最高代次，且 `previous_generation` 不能超前；同一份描述符被重放时返回 `stale_generation`，不会把客户端退回旧权威。
- **状态不靠信任**：`content_digest` 提交到具体快照，篡改状态即签名失效；摘要不含地址与时间，因此同样的状态搬到新地址仍得到同一摘要。

## 验证

`tests/m4_move_test.gd`：父进程作为真实成员客户端，两个真实宿主进程（回环 WSS、自签证书、隔离目录 `.local/verification/m4-move-*`）。第一阶段跑 `primary`，第二阶段跑从搬迁快照启动的 `successor`。

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 240 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_move_test.gd"
```

结果：`M4_MOVE_TEST checks=31 failures=0`，本机连续复跑 3 次均通过。纯签名规则的独立用例 `WORLD_IDENTITY_TEST checks=24 failures=0`。

| 用例 | 实际输出 | 结果 |
|---|---|---|
| 停写生效 | 宿主写入 `primary.retired` 后客户端才提交 | 通过 |
| 已连成员被拒 | `ok=false, reason=read_only, sequence=1` | 通过 |
| 拒绝不落盘 | 重载旧世界 `transaction.sequence=1` | 通过 |
| 描述符签名 | `ok=true`，新代次 2、承接序号 1、含新地址 | 通过 |
| 已见代次重放 | `stale_generation` | 通过 |
| 后继承接 | 新命令 `ok=true, sequence=2` | 通过 |
| 搬迁后幂等 | 旧命令 id 返回 `duplicate=true`，序号仍为 2 | 通过 |
| 落盘一致 | 新世界 `transaction.sequence=2`，库存无额外发放 | 通过 |

用例已加入 `.github/workflows/rule-tests.yml`，双平台绿色证据：CI 运行 `43634026461`（提交 `184ce2e`），`rules (macos-latest)` 与 `rules (windows-latest)` 均通过。

## 未覆盖

- 停写信号由测试写文件触发，没有做成运维入口（API/命令/控制台）；也还没有“等待在途命令完成再停写”的排空流程，当前语义是停写后立即拒绝新命令。
- 搬迁需要人工把 `world` 目录复制到新主机；没有内建打包、传输或校验步骤，`content_digest` 只在描述符里被验证，没有在接收端重新计算比对。好友/联系人当时不存在于世界数据中；[M5-01](../M5/RECORD-01-social.md) 之后，世界包 v2 的 `world.json` 与存档目录的 `social.json` 已随导出/导入携带，但搬迁流程本身仍按目录复制处理。
- 客户端侧只验证了描述符与重连，没有实现“收到描述符后自动切换地址”的流程，也没有 `authority_lost` 之后的界面提示。
- 生成密钥与自签证书仍是测试内生成，没有持久化世界密钥的存储与轮换方案（密钥丢失即无法为后续代次签名）。
- 没有覆盖迁移中途失败回滚：当前只保证旧权威已停写，回滚到旧权威需要重新打开写权限，测试未覆盖。
- 没有跨机器/跨平台手工验证；仓库尚无对外服务器部署入口（M4-05）。

## 关联

- 前序：[M4-03 同步与重连](RECORD-02-sync.md)；传输与身份裁决 [ADR-004](../../decisions/ADR-004-transport.md)。
- 事务账本与幂等窗口：[M3-03](../M3/RECORD-03-commit-recovery.md)。
- 阶段计划：[M4 PLAN](PLAN.md) M4-04。
