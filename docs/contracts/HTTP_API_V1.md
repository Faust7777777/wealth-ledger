# HTTP_API_V1

状态：草案。  
用途：未来 VPS / api remote 的 HTTP 接口草案。  
非用途：当前前端第一阶段不实现这些真实请求；本文件用于提前固定接口边界。

## 0. 基础约定

Base path:

```text
/v1
```

通用响应：

```json
{
  "ok": true,
  "data": {}
}
```

错误响应：

```json
{
  "ok": false,
  "error": {
    "code": "string",
    "message": "string",
    "severity": "error",
    "retryable": false,
    "details": {}
  }
}
```

写请求约束：

- 除认证生命周期接口外，所有账本写请求必须携带 `Idempotency-Key`；取值为 1–128 个可见 ASCII 字符。
- 客户端重试同一操作时必须复用原 key；同 key、同操作、同 JSON 请求会返回首次提交的原始 HTTP 状态码和响应体，并附 `Idempotency-Replayed: true`。
- 同 key 用于不同路径或不同 JSON 请求返回 `409 idempotency_key_reused`；缺失、重复或格式非法返回 `400 invalid_idempotency_key`。
- 服务端只在 `ledger.json` 保存 key 的 SHA-256 摘要、请求摘要、操作名、完整响应与时间戳，不保存原始 key；业务变更和幂等记录必须通过同一次临时文件写入与原子 rename 提交。
- 当前幂等记录保留 30 天，最多 5000 条；超过上限优先淘汰最早记录。保留期结束后再次使用旧 key 会被视为新请求。
- 所有写请求必须鉴权。
- debug fixture / DEMO 数据禁止上传。
- 服务端不得提供转账、下单、交易权限接口。

## 1. Health

```http
GET /v1/health
```

返回：

```json
{
  "ok": true,
  "data": {
    "status": "ok",
    "serverTime": "2026-06-25T12:00:00+08:00",
    "version": "0.1.0"
  }
}
```

## 2. Auth

```http
POST /v1/auth/login
POST /v1/auth/refresh
POST /v1/auth/logout
GET  /v1/auth/devices
POST /v1/auth/devices/{deviceId}/revoke
```

登录请求：

```json
{
  "username": "string",
  "password": "string",
  "deviceName": "Windows PC"
}
```

返回：

```json
{
  "ok": true,
  "data": {
    "accessToken": "string",
    "refreshToken": "string",
    "expiresAt": "2026-06-25T13:00:00+08:00",
    "refreshExpiresAt": "2026-07-25T13:00:00+08:00",
    "deviceId": "id"
  }
}
```

规则：

- 暂不做 2FA。
- 服务端只存密码哈希。
- access/refresh token 是随机 opaque token，服务端仅保存 token hash，不使用 JWT。
- logout 可通过可选 body 的 `refreshToken` 撤销 refresh token；未提供 body 时可通过 bearer token 撤销当前 access token。
- token 不写日志。

## 3. Bootstrap

```http
GET /v1/ledger/bootstrap
```

用途：新设备拉取当前账本摘要与同步游标。

返回：

```json
{
  "ledgerVersion": 1,
  "syncCursor": "string",
  "baseCurrency": "CNY",
  "snapshot": {},
  "accounts": [],
  "categories": [],
  "counterparties": [],
  "capabilities": {
    "dataSourceMode": "real_local",
    "canWriteConfirmedLedger": true,
    "canCreateAccount": true,
    "canRecordMovement": true,
    "canConfirmProposal": true,
    "canPersistPendingProposal": true,
    "proposalPersistence": "file",
    "canRefreshQuotes": true,
    "canUseOutboundQuoteProvider": false,
    "canSync": false,
    "canUseRealAiProvider": false
  }
}
```

## 4. Accounts

```http
GET    /v1/accounts
POST   /v1/accounts
GET    /v1/accounts/{accountId}
PATCH  /v1/accounts/{accountId}
POST   /v1/accounts/{accountId}/archive
GET    /v1/accounts/anomalies
```

规则：

- 账户字段使用 `DATA_SCHEMA_V1.Account`。
- 归档不等于删除。
- 资产账户负数才可能触发 `negative_balance`。

## 5. Portfolio / Holdings

```http
GET /v1/portfolio/overview
GET /v1/portfolio/holdings
GET /v1/holdings
GET /v1/accounts/{accountId}/holdings
GET /v1/portfolio/allocation
```

规则：

- overview 返回 `APPLICATION_INTERFACES_V1.PortfolioOverview`。
- holdings 来自同一底层数据，投资页与账户详情只是两种投影。
- 主要持仓按市值占比排序，不按收益率排序。

## 6. Movements

```http
GET   /v1/movements
GET   /v1/movements/recent
POST  /v1/movements/drafts
GET   /v1/movements/{movementId}
POST  /v1/movements/{movementId}/submit-review
POST  /v1/atomic-groups/{atomicGroupId}/confirm
POST  /v1/atomic-groups/{atomicGroupId}/reject
POST  /v1/movements/corrections
```

查询语义：

- `/movements?status=<MovementStatus>&limit=1..200` 先按状态过滤，再截断；未传参数时保留账本顺序。
- `/movements/recent?limit=1..200` 按 `occurredAt`、`recordedAt`、`id` 稳定倒序，缺省返回最近 20 条。
- 非法 status 或 limit 返回 400 `invalid_movement_query`，不得静默忽略。

规则：

- draft / pending review 不影响正式余额。
- `atomicGroupId` 是最小确认单位。
- confirmed movement 的修改优先走 correction。

## 7. DCA

```http
GET   /v1/dca/plans
POST  /v1/dca/plans
PATCH /v1/dca/plans/{planId}
GET   /v1/dca/reminders/due
POST  /v1/dca/reminders/{reminderId}/mark-executed-as-proposal
POST  /v1/dca/reminders/{reminderId}/skip
POST  /v1/dca/reminders/{reminderId}/snooze
```

规则：

- `mark-executed-as-proposal` 只生成 pending AI / manual proposal 或 draft，可持久化用于复核。
- 不下单。
- 不转账。
- 不连接券商交易接口。
- 用户确认前不写 confirmed/effective ledger；确认 atomic group 后才影响余额、持仓、净值和快照。

## 7A. Subscriptions

```http
GET   /v1/subscriptions
POST  /v1/subscriptions
GET   /v1/subscriptions/upcoming?days=30
GET   /v1/subscriptions/{subscriptionId}
PATCH /v1/subscriptions/{subscriptionId}
POST  /v1/subscriptions/{subscriptionId}/cancel
POST  /v1/subscriptions/{subscriptionId}/charge-proposal
```

订阅用于管理 ChatGPT Plus、Claude Pro 等周期性服务费用：

- 金额始终保存原币种，不因首页本位币估值而改写原始订阅金额。
- `billingCycle` 支持日、周、自然月、自然年及正整数间隔。
- 自然月/年保留最初扣款日作为 `billingAnchorDay`；31 日遇短月取月末，后续月份恢复锚点，不永久漂移到 28 日。
- 创建时可提供 `duration` 或 `endDate`，二者互斥；不提供表示持续订阅。
- PATCH 将 nullable `duration`/`endDate` 视为一组排期替换字段：二者都非空时冲突；`duration` 非空时按 `startDate` 计算 `endDate`；仅 `endDate` 非空时移除 `duration`；两者都为 `null` 时清除有限期限。
- subscription 计划本身不写支出。`charge-proposal` 只创建 `pending_review` expense，确认 atomic group 后才影响账户余额并推进 `nextChargeDate`；拒绝后允许重新生成同一期候选。
- 取消不会删除历史 movement，只停止未来计划扣款。
- 所有写操作必须提供 `Idempotency-Key`。

## 8. AI Proposals

```http
POST /v1/ai/proposals/from-text
POST /v1/ai/proposals/from-image
POST /v1/ai/proposals/from-csv
GET  /v1/ai/proposals/pending
GET  /v1/ai/proposals/{proposalId}
POST /v1/ai/atomic-groups/{atomicGroupId}/approve
POST /v1/ai/atomic-groups/{atomicGroupId}/reject
POST /v1/ai/atomic-groups/{atomicGroupId}/edit
```

规则：

- AI 端点只创建或修改 proposal。
- approve 前必须校验。
- 修改已有记录必须返回 old → new diff。
- full ledger context 只用于生成候选，不授权 AI 写账。

## 9. Quotes / FX / Historical Prices

```http
GET  /v1/quotes/summary
GET  /v1/quotes
GET  /v1/fx-rates
POST /v1/quotes/refresh
GET  /v1/instruments/{instrumentId}/historical-prices?from=YYYY-MM-DD&to=YYYY-MM-DD
```

规则：

- refresh mode 支持 `manual` / `startup` / `scheduled`。
- 断网时客户端可使用缓存并标记 `offline_cached`。
- 历史价格 MVP 固定近一年上限。
- AI 搜索补价格时必须附 evidence，用户确认后才采用。

## 10. Snapshots

```http
GET  /v1/snapshots/latest
GET  /v1/snapshots?from=YYYY-MM-DD&to=YYYY-MM-DD
POST /v1/snapshots/manual
POST /v1/snapshots/invalidate
```

规则：

- 不传 `from/to` 时返回全部持久化快照，按 `snapshotAt` 倒序。
- 日期范围为包含首尾的本地日历日期；`from/to` 必须同时出现，格式错误或 `to < from` 返回 400 `invalid_snapshot_range`。
- 首页默认较上次快照。
- 只有全 fresh 时才展示今日涨跌。

## 11. Categories / Counterparties

```http
GET   /v1/categories
POST  /v1/categories
GET   /v1/categories/{categoryId}
PATCH /v1/categories/{categoryId}
GET   /v1/counterparties
POST  /v1/counterparties
GET   /v1/counterparties/{counterpartyId}
PATCH /v1/counterparties/{counterpartyId}
POST  /v1/counterparties/merge-proposal
```

规则：

- “咖啡”不应自动归并到“瑞幸咖啡”。
- 合并建议必须经用户确认。

## 12. Sync

```http
GET  /v1/sync/bootstrap
GET  /v1/sync/changes?since=<cursor>
POST /v1/sync/push
POST /v1/sync/ack
```

规则见 `SYNC_API_DRAFT.md`。

当前 real-local 阶段只实现本地 outbox：

- account create / update / archive 会追加 `SyncChange`。
- confirmed movement create / correction 会追加 `SyncChange`；draft、pending proposal、未确认图片/CSV 不进入 outbox。
- `GET /v1/sync/changes?since=<cursor>` 返回该 cursor 之后的本地 change。
- 空日志使用 genesis cursor `local_cursor_0000`；从该 cursor 拉取会返回完整保留日志，从该 cursor ack 是幂等 no-op。
- 除 genesis 外，未知 `since` cursor 返回 `400 invalid_sync_cursor`，不得静默从头重放。
- pull 响应中的 `cursor` 与 `changes` 来自同一次账本快照，cursor 不得超前于响应内 change。
- `POST /v1/sync/ack` 接收 `cursor` 或 `changeIds`，成功后清理本地 `pendingChangeIds`，但保留 `syncChanges` 日志。
- 当前 ack 是单一上游对本地 outbox 的高水位确认，不代表每台 Android/Windows 设备分别收妥。
- 新 change ID 必须同时参考 `nextChangeSequence` 和已有最大 `local_change_N`，防止计数器回退后复用 ID。
- 磁盘日志中的 change ID 必须唯一且严格递增；非空日志 cursor 必须等于日志尾，pending ID 必须唯一、存在、保持日志顺序且只指向本地 change。
- `POST /v1/sync/push` 会把远端 `SyncChange` 作为同步日志中继保存，并返回 `acceptedChangeIds` / `skippedChangeIds`；不会直接应用到账本实体。
- 远端 push 的 `createdAt` 必须是 RFC3339，不能冒用保留设备 ID `local_device`；相同 `(sourceDeviceId, sourceChangeId)` 只保存一次。
- 不做远端 merge、不做冲突解决、不做 E2EE 同步。

## 13. 明确禁止的 HTTP 端点

这些端点不得出现：

```http
POST /v1/transfers/execute
POST /v1/broker/orders
POST /v1/broker/buy
POST /v1/broker/sell
POST /v1/ai/auto-approve
POST /v1/ai/write-ledger-directly
POST /v1/coupons/plan
```
