# 2026-07-13 后端继续开发审查

范围：Claude 继续 Flutter 订阅接线期间，Codex 只推进不冲突的 Rust、同步、发布和
数据安全线路。

## 已选当前任务：Windows 本地备份恢复加固

审查前的本地脚本存在真实数据风险：

- 备份先验证源文件再复制，验证与副本之间存在时间窗口。
- auth 状态会被复制但不做 Rust 语义验证。
- 备份目录直接发布，失败时可能留下看似完整的半成品。
- 恢复不验证 manifest 或 SHA-256。
- 无 auth 的备份恢复后会保留旧 auth，形成混合快照。
- 直接覆盖 live 文件，第二个文件失败时没有双文件回滚。
- 没有 Windows 本地备份/恢复端到端 smoke。

本轮要求：备份在私有 staging 中复制并验证 ledger/auth，生成固定文件名的
`manifest.txt` 和 `SHA256SUMS` 后再发布；恢复默认只接受已验证目录，先创建
pre-restore backup，在目标目录 stage 后替换，任何中途或写后验证失败都恢复账本和
auth 的原状态。无 auth 的已验证备份必须删除 live auth。所有破坏性测试只在系统临时
目录运行。

## 同步审查：不要用扩大 outbox 冒充多设备完成

当前 `POST /v1/sync/push` 只把远端 change 保存到日志，不应用到账本实体，响应中的
`conflicts` 始终为空。此时一次性给 quote、snapshot、AI proposal 等更多写入追加
outbox，只会制造更多不可消费日志，并不会让设备收敛。

下一条真实同步切片应严格限制为认证设备的 `account/create` inbound apply：

1. Bearer token 解析真实 auth device ID，拒绝请求体冒充设备。
2. 校验 `payload.id == entityId`、完整账户结构与 `baseVersion`。
3. 账户写入和远端 sync log 落盘必须是同一个原子 ledger write。
4. 相同 source device/change 重试只 skip，不重复应用。
5. 已存在相同 entity ID 时返回 conflict，不使用 last-write-wins。
6. 远端 change 不进入目标 outbox，避免回声。
7. 响应区分“日志接收”与“实体已应用”，例如增加 `appliedChangeIds`。

在 account create inbound apply 完成前，不实现 account update、金额冲突或 confirmed
movement 的自动合并。

默认排除：

- quote/FX：带时效的 provider cache，应集中获取或各设备刷新。
- snapshot/holding：confirmed ledger 的派生物，应重算。
- AI proposal/evidence：可能包含文本、图片或 CSV 敏感数据；默认只同步确认后的
  movement。
- counterparty merge：是目标更新、来源删除、历史引用重映射的原子多实体操作，不能用
  单个普通 update 代替。

## 后续独立后端任务

### P0：修复 CI/package 假绿

审查时 CI 会捕获 `CLIENT_IDEMPOTENCY_BLOCKER` 并只写 Warning，可能没有产出 Windows
包却显示成功。本轮已移除该吞错路径，并让 readiness 运行明确的 auth client 行为测试；
手动 Package workflow 在构建前运行 Flutter、Rust、contract 和 smoke 门禁。包 manifest
升级为记录 source commit/dirty 状态和 client/server/launcher/build-config 哈希，zip 另带
SHA-256，且归档前后均运行无用户状态副作用的 launcher integrity check。

### P1：修复已公开查询语义

- `/movements` 已声明 `limit/status`，real-local 尚未完整执行过滤和限制。
- `/movements/recent` 应按时间倒序，而不是依赖文件插入顺序。
- `/snapshots` 已声明 `from/to`，服务端应校验并过滤，不能忽略参数。

### P1：订阅到期批量维护

当前只有逐条 `charge-proposal`。可以增加确定性的 due scan：对
`nextChargeDate <= today` 且 active/trial、无 pending 的订阅生成待确认候选；每个周期最多
一个，绝不自动确认或扣账。应等 Claude 当前单条订阅闭环稳定后再增加契约和前端触发点。

### P2：账本耐久与迁移

建立显式 migration registry、临时文件 flush/fsync、遗留 `.tmp` 恢复策略和多进程文件
锁。不要仅依赖进程内 mutex 与读取时补字段。
