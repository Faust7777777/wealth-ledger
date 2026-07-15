# LOCAL_LEDGER_FORMAT_V1

状态：当前实现契约。
用途：定义 `--ledger-path` 真实本地账本的磁盘格式、备份边界、fixture 隔离和校验入口。
非用途：不承诺 SQLite/多文件目录结构；不定义远端同步数据库格式。

## 0. 当前物理格式

当前真实本地业务账本是一个 UTF-8 JSON 文件，由 Rust local ledger 读写；启用持久化登录时还会有一个独立的 auth 状态文件：

```text
ledger.json
ledger.json.tmp   // 写入中临时文件；主文件缺失时仅在完整校验通过后自动恢复
ledger.auth.json  // 可选；设备与 token 哈希状态，不属于业务账本
ledger.json.lock  // 永久 sidecar；服务进程持有 OS 文件锁，文件本身不删除
```

规则：

- `ledger.json` 是唯一真实业务账本文件；`ledger.auth.json` 仅保存本地认证状态，不包含明文 token，也不得混入账本 JSON。
- `ledger.json.lock` 是进程协调 sidecar，不是账本、auth 状态或备份完整性证据；不得根据文件是否存在判断服务是否正在运行。
- 不存在 `accounts.csv`、`movements.csv`、`ledger.db` 等正式磁盘文件。
- 写入流程必须是：读取现有 JSON → 内存中修改 → schema/invariant 校验 → 写入同目录 `.tmp` → flush/sync 文件 → 原子 rename 覆盖 `ledger.json` → sync 已提交文件（Unix 另 sync 父目录元数据）。
- 启动时若 `ledger.json` 不存在但 `ledger.json.tmp` 存在，只在临时文件能完整解析并通过账本校验时自动提升为主文件。
- 无效临时文件必须保留并 fail-closed，不得静默初始化空账本。主文件存在时始终以主文件为权威，临时文件不得自动覆盖它。
- 已存在但损坏/截断的 `ledger.json` 不得被静默重建；必须返回错误，让用户先备份或人工恢复。
- 新建账本只允许发生在目标 `ledger.json` 不存在时。

## 0A. 服务生命周期独占 lease

使用 `--ledger-path` 启动时，Rust 服务必须在读取、初始化账本或打开 sibling auth 状态之前，对规范化账本路径完整追加 `.lock` 得到 sidecar 路径，并获取独占 OS 文件锁。例如 `ledger.json` 对应 `ledger.json.lock`，不是替换 `.json` 扩展名。

规则：

- lease guard 由 `AppState` 以 `Arc<LedgerLease>` 持有，直到服务退出；不得只锁住单次 `write_document` 或单个 read-modify-write。
- 默认最多等待 3 秒获取 lease。第二个指向同一规范化 ledger 路径的服务实例超时后必须 fail-closed，不得以只读、无 auth 或新建空账本方式继续。
- 同一 lease 同时界定 `ledger.json`、其临时替换文件与 sibling `ledger.auth.json` 的服务级所有权，避免两个进程分别改写业务与认证状态。
- 崩溃、强制终止或正常 drop 时由操作系统释放锁；sidecar 文件永久保留，服务不得删除它。
- 当前 JSON 账本只支持单机单服务进程，不支持 active-active、多写者或通过共享文件系统横向扩展。
- 实现使用 Rust 标准库文件锁 API，最低 Rust 版本必须为 1.89。

## 1. 数据源模式

```ts
DataSourceMode =
  | "real_local"      // Flutter 默认空实现，不直接读写 JSON
  | "debug_fixture"   // DEMO/fixture，必须隔离
  | "local_server";   // Flutter 通过 Rust localhost server 访问 --ledger-path
```

规则：

- Flutter 不直接读写 `ledger.json`。
- `local_server` 才能通过 HTTP 调 Rust local ledger。
- `debug_fixture` 只能在 debug/demo 模式启用，必须有可见 `DEMO` 标记。
- fixture 数据不得同步、不得备份进真实账本、不得和 `ledger.json` 共用文件。

## 2. 顶层 JSON 结构

`ledger.json` 顶层对象至少包含这些字段，字段名以实际 JSON/camelCase 为准：

```json
{
  "ledgerVersion": 1,
  "baseCurrency": "CNY",
  "metadata": {},
  "accounts": [],
  "instruments": [],
  "holdings": [],
  "movements": [],
  "movementEntries": [],
  "dcaPlans": [],
  "dcaReminders": [],
  "subscriptions": [],
  "categories": [],
  "counterparties": [],
  "quotes": [],
  "fxRates": [],
  "snapshots": [],
  "aiProposals": [],
  "evidenceRefs": [],
  "anomalies": [],
  "syncState": {
    "cursor": null,
    "nextChangeSequence": 1,
    "pendingChangeIds": []
  },
  "syncChanges": [],
  "idempotencyState": {
    "version": 1,
    "records": {}
  },
  "migrations": []
}
```

说明：

- API 响应可以是投影/聚合结果；磁盘格式不是 HTTP 响应格式。
- `movements` 是业务事件；`movementEntries` 是分录明细。
- `aiProposals` 保存 AI 原生候选与复核状态；standalone `pending_review` movement 不得为了 AI Review 可见性再复制到该数组。读取层按 `atomicGroupId` 动态投影这类候选，确认前不得影响正式余额、净值、持仓。
- `syncChanges` 是本地/远端同步变更日志，不等于业务流水。
- 空日志对外使用 genesis cursor `local_cursor_0000`，磁盘上的 `syncState.cursor` 仍为 `null`。
- `syncState.nextChangeSequence` 是持久化提示值；生成新 ID 时必须同时扫描已有最大 `local_change_N`，不得因字段回退而复用 change ID。
- `pendingChangeIds` 是本地 outbox 的待上游确认集合，不代表每台客户端的独立同步进度。
- `syncChanges[*].id` 必须是规范化、唯一且按日志顺序严格递增的 `local_change_N`；允许 sequence 有空洞，不允许重复或倒序。
- 空日志的磁盘 cursor 必须为 `null`；非空日志的 `syncState.cursor` 必须等于最后一条 change ID。
- `pendingChangeIds` 必须唯一、保持日志顺序、只引用仍存在的本地 change；远端中继 change 不得进入本地 outbox。
- 当前认证设备的 `account/create` 入站应用必须在一次文件事务中同时追加完整 Account 与远端中继 change；任一校验或写入失败时两者都不得出现。
- 远端中继 change 必须同时带 `sourceDeviceId` / `sourceChangeId`，二者组合在日志内唯一，并带合法 RFC3339 `receivedAt`；`sourceDeviceId` 来自认证上下文而非请求体。相同来源重放不重复应用实体。
- `idempotencyState.records` 以 `Idempotency-Key` 的 SHA-256 URL-safe 摘要为键；记录请求摘要、具体操作、首次状态码/响应体、创建与过期时间，不得保存原始 key。

## 3. 空账本初始化

第一次创建 `ledger.json` 时：

- `accounts`、`holdings`、`movements`、`movementEntries`、`dcaPlans`、`subscriptions`、`aiProposals` 必须为空。
- base currency 默认 `CNY`。
- 不得自动注入示例资产。
- 不得默认加载 fixture。
- 首页应显示空状态 CTA：建账户 / 记录基线。

## 3A. 订阅计划

`subscriptions` 保存周期费用计划，不等同于 confirmed movement。旧 v1 账本缺少该字段时读取层补成空数组，不要求手工迁移。

核心字段：

- `amount`：正数 decimal string + 原币种。
- `billingCycle`：`day|week|month|year` 与正整数 `interval`。
- `billingAnchorDay`：自然月/年计算锚点，短月只临时落到月末。
- `startDate`、可选 `duration`/`endDate`、可空 `nextChargeDate`。
- `paymentAccountId`：必须引用现有账户。
- `status`：`trial|active|paused|cancelled|expired`。
- `pendingChargeMovementId` 与 `pendingChargeDate` 必须成对出现。

创建或更新 subscription 时，付款账户必须存在、未归档，且 `supportedCurrencies` 包含 `amount.currency`。账户后续归档或支持币种变更不自动改写旧计划；每次生成候选都重新检查，避免在币种能力漂移后静默换汇或写入不可执行候选。

生成扣款候选时新增 `pending_review` movement 及其 entries，并在同一 document 中写入 subscription 的 pending 指针；不额外持久化 `aiProposals` 副本。确认 atomic group 后，订阅才记录 `lastChargeMovementId/lastChargeDate` 并推进下次日期；拒绝候选则把 movement 标记为 `cancelled`、清除 pending 引用并保留原计划日期，历史候选及 entries 仍留在账本中用于追溯。

磁盘校验必须维持双向不变量：

- `pendingChargeMovementId` 与 `pendingChargeDate` 同时存在或同时缺失。
- pending ID 必须引用存在且状态为 `pending_review` 的 movement。
- movement 的 `subscriptionId` 与 subscription ID 一致，`scheduledChargeDate` 与 `pendingChargeDate` 一致。
- 每个 subscription/计费日期最多一个 pending 候选；带 `subscriptionId` 的 pending movement 不得成为没有 subscription pending 指针的孤儿。

`POST /v1/subscriptions/charge-proposals/due-scan` 在一次账本锁定/read-modify-write 中完成稳定排序、逐项 skip、全部候选创建、pending 指针更新和幂等记录保存，并只提交一次。limit 仅限制创建数量；已 pending 或付款能力漂移的项目仍进入 `skipped[]`，不会阻断其他项目。该命令不改变 `ledgerVersion`，也不是后台自动扣款任务。

AI pending 读取层把 standalone pending movements 按 `atomicGroupId` 分组，动态生成 `proposal_movement_{movementId}` 形式的 proposal 投影；列表、详情和 overview pending count 都包含该投影。确认/拒绝仍直接消费原 movement atomic group；投影不可编辑，处理完成后自然消失。

## 3B. DCA 计划与提醒完整性

`dcaPlans` 与 `dcaReminders` 是提醒排期和真实成交候选的来源，不是券商订单。

- plan/reminder ID 各自唯一；reminder 的 `planId` 必须引用现有 plan。
- `plannedAmount` 必须是正 decimal string，`nextDueDate` / `dueDate` 必须是 ISO date。
- plan 的 frequency/status 与 reminder status 必须属于契约枚举。
- `fundingAccountId` 存在时必须引用账本账户；是否归档和币种能力在生成成交候选时再次检查。
- 同一 plan 最多有一个 `due|overdue|snoozed` 的开放 reminder；开放 reminder 的名称、计划金额和日期必须与 plan 同步。
- snoozed reminder 必须带 RFC3339 `snoozedUntil`，其他状态不得残留该字段。
- 带 `tags=["dca"]` 且 `source.kind=system` 的 movement 必须通过 `source.sourceId` 引用现有 reminder。
- 同一 reminder 最多一个 `pending_review` DCA movement；`recorded` reminder 必须且只能关联一个 confirmed DCA movement。

这些不变量在启动读取、备份验证和每次原子写盘前统一校验；违反时 fail closed，不自动删除或修补用户数据。

## 4. 写入原则

正式账本写入必须满足：

- 写操作以 atomic group 或单个明确命令为事务边界。
- HTTP 写操作的业务变更与幂等结果必须进入同一份内存 document，并只调用一次 `write_document`；不得在业务写入成功后另写旁路 cache。
- 同 key、同请求命中未过期记录时不得再次执行领域修改；必须原样重放保存的状态码/响应体。同 key、不同请求必须拒绝。
- 写入前完成金额、币种、账户引用、分录方向、AI validation 等校验。
- decimal string 必须使用统一校验口径；当前最多允许 8 位小数。
- 已确认记录更正必须生成 correction movement，不静默覆盖原记录。
- 多腿更正必须在一个 correction movement 内包含全部原分录的反向腿和完整 replacement 腿；确认时作为单个 atomic group 应用，不允许部分确认。
- 同一 confirmed movement 同时最多有一个 pending correction；账本效果未变化的 replacement 不得落盘。
- AI approve 必须消费服务端 `ledgerWrite` / `confirmedMovementIds`，前端不得自行猜测“已入账”。
- 写入后如影响净值/持仓/快照，必须返回或标记 `snapshotInvalidated`。

## 5. 迁移原则

当前实现版本仍是 `ledgerVersion: 1`，迁移 registry 是有意保持为空的骨架。本切片不会把账本升到 v2，也不提供会改写磁盘的自动迁移。

普通 `read_document` 只允许执行不改变领域语义的 v1 read compatibility：

- 顶层缺少 `subscriptions` 时在内存视图中补 `[]`。
- 顶层缺少 `syncChanges` 时在内存视图中补 `[]`。
- 顶层缺少 `idempotencyState` 时在内存视图中补 `{ "version": 1, "records": {} }`。
- 仅当 `syncState` 已存在且是 object 时，才可为缺少的 `nextChangeSequence` 补 `1`。
- 缺少整个 `syncState`、缺少 `syncState.cursor` 或缺少 `syncState.pendingChangeIds` 必须 fail-closed；读取层不得猜测 cursor，也不得清空或重建 outbox。

上述兼容补齐只修改当次读取的内存文档；单纯读取不得写回 `ledger.json`、追加 `migrations[]` 或提升 `ledgerVersion`。它是 v1 内的可选字段兼容，不是版本迁移。

初始化和 `.tmp` 恢复只允许发生在显式 init 或服务启动阶段。服务运行后的业务读取与写事务必须读取已存在的主账本；若 `ledger.json` 消失，必须 fail-closed，不得在下一次请求中静默创建空账本。

```ts
Migration {
  id: string;
  fromVersion: number;
  toVersion: number;
  appliedAt: ISODateTime;
  checksum?: string;
}
```

规则：

- registry 中的 migration ID 必须唯一，版本边必须严格连续且不得分叉；空 registry 对当前 v1 是合法状态。
- 迁移器必须先创建经过校验的完整备份目录；存在同名 auth 状态时应与 `ledger.json` 一并纳入快照。
- 迁移失败不得覆盖原账本。
- 迁移必须可重复检测，不能重复应用同一 migration。
- 迁移完成后必须执行完整账本校验。
- 首次真实版本升级必须由显式的备份+迁移命令触发：先生成并校验包含 ledger/auth 的快照，再按 registry 路径迁移、校验并原子替换。服务启动或普通 API 读取不得暗中触发该流程。

## 6. 备份、恢复与导出

当前 Windows 自用备份以 `tools/backup_local_ledger.ps1` 生成的目录为边界，不再把手工复制单个 `ledger.json` 视为完整、可验证备份：

- 先在备份根目录的未发布 staging 目录复制 `ledger.json`，以及存在时的 `ledger.auth.json`。
- 复制前后比较源文件 SHA-256 与 auth 存在性；复制期间源状态变化则失败并删除 staging，避免发布混合时点快照。
- 默认使用 Rust `--validate-ledger` / `--validate-auth-state` 校验 staging 副本。
- staging 内生成固定文件名 `manifest.txt` 与 `SHA256SUMS`，记录格式版本、是否包含 auth 及校验状态，再以目录移动发布最终备份。
- 备份不包含 fixture、明文运行时 token、密码、服务端 env 或外部设备密钥；auth 文件只包含设备信息与 token 哈希，仍应按敏感数据保护。

当前恢复以 `tools/restore_local_ledger.ps1` 为准：

- 默认只接受带 `manifest.txt` / `SHA256SUMS` 且内容一致的备份目录；直接文件或损坏/缺失清单只能通过显式 `-AllowUnverified` 进入应急路径。
- 当前 live ledger 存在时，替换前先创建 pre-restore 备份；恢复事务还会在目标目录 stage 账本/auth，并重新校验 SHA-256 和 Rust 语义。
- 已验证备份包含 auth 时同时恢复；明确 `includesAuth=false` 时删除旧 live auth，禁止把新账本与旧登录状态拼成混合快照。
- ledger/auth 替换开始后的任何失败或写后验证失败，都必须恢复两者各自的原始存在状态和内容。
- `-SkipValidate` / `-AllowUnverified` 只用于明确的应急恢复，不应作为日常备份或发布验收路径。

CSV 导入导出是应用层能力，不是当前本地账本的物理格式。

未来如提供 CSV 导出，应明确标注为“导出视图”，不是可直接替代 `ledger.json` 的完整备份。

## 7. 安全边界

- `ledger.json` 可能包含完整资产、账户名称、AI evidence 摘要，默认应按敏感文件处理。
- `ledger.auth.json`、备份目录和 pre-restore 目录同样属于敏感本地状态。
- 不在日志中输出完整余额、token、密钥、原始图片内容。
- localhost server 必须保持 loopback bind，并通过 Host allow-list 防 DNS rebinding。
- 真实账本模式建议开启 auth；开发脚本不得无提示地以无 auth 方式打开真实账本。

## 8. 校验入口

本地账本至少需要这些校验：

- decimal string 格式与小数位数。
- currency code 非空。
- movement entries 引用的账户存在。
- instrument ID 唯一且核心字段、类型、报价币种有效。
- holding ID 与 `(accountId, instrumentId)` 组合唯一，数量非负，指向的 account / instrument 存在，成本与市值 Money 合法。
- movement ID、状态、类型、时间、tags 与 entries 完整；已确认/在途/已反向的持仓分录必须引用已存在 instrument。
- 顶层 `movementEntries` 索引必须与每个 `movement.entries` 的 ID 集合、movementId 和 atomicGroupId 完全一致，禁止悬空或漏项。
- transfer 双边账户存在且不直接执行外部转账。
- AI proposal 通过 validation 后才可 approve。
- debug fixture 与 real ledger 路径互斥。
