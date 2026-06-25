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

- 所有非幂等写请求必须支持 `Idempotency-Key`。
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
  "accessToken": "string",
  "refreshToken": "string",
  "expiresAt": "2026-06-25T13:00:00+08:00",
  "deviceId": "id"
}
```

规则：

- 暂不做 2FA。
- 服务端只存密码哈希。
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
  "counterparties": []
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
POST  /v1/movements/drafts
GET   /v1/movements/{movementId}
POST  /v1/movements/{movementId}/submit-review
POST  /v1/atomic-groups/{atomicGroupId}/confirm
POST  /v1/atomic-groups/{atomicGroupId}/reject
POST  /v1/movements/corrections
```

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

- `mark-executed-as-proposal` 只生成 AI / manual proposal。
- 不下单。
- 不转账。
- 不连接券商交易接口。

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

- 首页默认较上次快照。
- 只有全 fresh 时才展示今日涨跌。

## 11. Categories / Counterparties

```http
GET   /v1/categories
POST  /v1/categories
PATCH /v1/categories/{categoryId}
GET   /v1/counterparties
POST  /v1/counterparties
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

