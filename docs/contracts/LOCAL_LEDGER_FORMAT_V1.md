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
```

规则：

- `ledger.json` 是唯一真实业务账本文件；`ledger.auth.json` 仅保存本地认证状态，不包含明文 token，也不得混入账本 JSON。
- 不存在 `accounts.csv`、`movements.csv`、`ledger.db` 等正式磁盘文件。
- 写入流程必须是：读取现有 JSON → 内存中修改 → schema/invariant 校验 → 写入同目录 `.tmp` → flush/sync 文件 → 原子 rename 覆盖 `ledger.json` → sync 已提交文件（Unix 另 sync 父目录元数据）。
- 启动时若 `ledger.json` 不存在但 `ledger.json.tmp` 存在，只在临时文件能完整解析并通过账本校验时自动提升为主文件。
- 无效临时文件必须保留并 fail-closed，不得静默初始化空账本。主文件存在时始终以主文件为权威，临时文件不得自动覆盖它。
- 已存在但损坏/截断的 `ledger.json` 不得被静默重建；必须返回错误，让用户先备份或人工恢复。
- 新建账本只允许发生在目标 `ledger.json` 不存在时。

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
- `aiProposals` 只保存候选与复核状态；确认前不得影响正式余额、净值、持仓。
- `syncChanges` 是本地/远端同步变更日志，不等于业务流水。
- 空日志对外使用 genesis cursor `local_cursor_0000`，磁盘上的 `syncState.cursor` 仍为 `null`。
- `syncState.nextChangeSequence` 是持久化提示值；生成新 ID 时必须同时扫描已有最大 `local_change_N`，不得因字段回退而复用 change ID。
- `pendingChangeIds` 是本地 outbox 的待上游确认集合，不代表每台客户端的独立同步进度。
- `syncChanges[*].id` 必须是规范化、唯一且按日志顺序严格递增的 `local_change_N`；允许 sequence 有空洞，不允许重复或倒序。
- 空日志的磁盘 cursor 必须为 `null`；非空日志的 `syncState.cursor` 必须等于最后一条 change ID。
- `pendingChangeIds` 必须唯一、保持日志顺序、只引用仍存在的本地 change；远端中继 change 不得进入本地 outbox。
- 远端中继 change 必须同时带 `sourceDeviceId` / `sourceChangeId`，二者组合在日志内唯一，并带合法 RFC3339 `receivedAt`；保留的本地 device id 不得被远端 push 冒用。
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

生成扣款候选时只新增 `pending_review` movement。确认 atomic group 后，订阅才记录 `lastChargeMovementId/lastChargeDate` 并推进下次日期；拒绝候选则清除 pending 引用但保留原计划日期。

## 4. 写入原则

正式账本写入必须满足：

- 写操作以 atomic group 或单个明确命令为事务边界。
- HTTP 写操作的业务变更与幂等结果必须进入同一份内存 document，并只调用一次 `write_document`；不得在业务写入成功后另写旁路 cache。
- 同 key、同请求命中未过期记录时不得再次执行领域修改；必须原样重放保存的状态码/响应体。同 key、不同请求必须拒绝。
- 写入前完成金额、币种、账户引用、分录方向、AI validation 等校验。
- decimal string 必须使用统一校验口径；当前最多允许 8 位小数。
- 已确认记录更正必须生成 correction movement，不静默覆盖原记录。
- AI approve 必须消费服务端 `ledgerWrite` / `confirmedMovementIds`，前端不得自行猜测“已入账”。
- 写入后如影响净值/持仓/快照，必须返回或标记 `snapshotInvalidated`。

## 5. 迁移原则

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

- 迁移器必须先创建经过校验的完整备份目录；存在同名 auth 状态时应与 `ledger.json` 一并纳入快照。
- 迁移失败不得覆盖原账本。
- 迁移必须可重复检测，不能重复应用同一 migration。
- 迁移完成后必须执行完整账本校验。

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
- holding 指向 account / instrument 存在。
- transfer 双边账户存在且不直接执行外部转账。
- AI proposal 通过 validation 后才可 approve。
- debug fixture 与 real ledger 路径互斥。
