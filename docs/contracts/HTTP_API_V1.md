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

### 1.1 Client updates

```http
GET /v1/client-updates/{platform}/{channel}/latest
GET /v1/client-updates/{platform}/{channel}/assets/{fileName}
```

客户端更新端点公开可读，使未登录、登录过期和首次设置状态仍可升级。`latest` 返回不带通用 `ok/data` envelope 的 `ClientUpdateManifest`，并使用 `Cache-Control: no-store`；版本化 APK/ZIP 流使用 SHA-256 `ETag` 和 immutable cache。完整字段、发布原子性及客户端校验规则见 `CLIENT_UPDATE_V1.md`。

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
GET /v1/portfolio/valuation-issues
GET /v1/portfolio/holdings
GET /v1/holdings
GET /v1/accounts/{accountId}/holdings
POST /v1/accounts/{accountId}/holding-adjustment-proposals
POST /v1/accounts/{accountId}/holding-snapshot-proposals
POST /v1/accounts/{accountId}/crypto-instruments/ensure
GET /v1/liability-positions?throughDate=YYYY-MM-DD
GET /v1/accounts/{accountId}/repayment-schedule?limit=24
PATCH /v1/accounts/{accountId}/liability-terms
POST /v1/accounts/{accountId}/loan-interest-proposals
POST /v1/accounts/{accountId}/loan-payment-proposals
GET /v1/yield-positions?throughDate=YYYY-MM-DD
PATCH /v1/holdings/{holdingId}/yield-terms
POST /v1/holdings/{holdingId}/interest-proposals
GET /v1/portfolio/allocation
```

规则：

- overview 返回 `APPLICATION_INTERFACES_V1.PortfolioOverview`。
- holdings 来自同一底层数据，投资页与账户详情只是两种投影。
- `Holding.marketValue` 始终按账本本位币折算，供组合/净资产聚合；`accountMarketValue` 按所属账户 `defaultCurrency` 折算，供账户内持仓合计。两者缺少报价或 FX 路径时分别缺失，不得由客户端混用币种求和。
- 主要持仓按市值占比排序，不按收益率排序。
- 持仓调整输入目标 quantity，不由客户端计算最终余额。服务端在同一账本锁内读取旧 quantity、生成 pending adjustment，并在确认时做 optimistic check；确认前持仓不变。
- 持仓快照一次接收同一账户的 1–100 个标的，所有变化项进入同一个 atomic group。重复标的、负数、未知标的、不受支持的计价币种或既有 pending adjustment 会使整次请求失败；数量未变化的项目只在 `skippedPositions` 报告。快照组元数据随 pending movement 持久化，刷新待审核列表后仍保留标题、目标账户和未变化项。整组确认或拒绝，不逐项落账。
- 该入口用于导入或校准交易所/券商当前持仓，不伪造现金买入。成本未知时不生成成本基础；原始 quantity 始终保留，缺报价时不得按 0 估值。
- `crypto-instruments/ensure` 登记或复用用户消息、附件或查询结果中实际出现的加密资产代码，并补齐账户的报价币种支持；服务端规范化代码并生成真实 `instrumentId`，不接受模型自造 ID。它不创建持仓、余额、报价或 movement。Agent 在持仓快照遇到缺失标的时必须先调用该接口，随后仍只生成待审核快照。内置 public provider 仍只为其明确支持的资产提供结构化行情；其他资产没有报价时保留原始数量并逐项报告缺报价。
- 持仓估值允许使用最多三跳的 FX 路径，例如 `BTC quantity × BTC/USDT quote × USDT/USD × USD/CNY`；每一段必须来自已保存的有效 Quote/FXRate，结果质量取整条路径中最差状态。
- `valuation-issues` 是估值问题的权威逐资产读模型，返回账户、资产、原始数量、状态和结构化 reason；不返回面向用户的解释文案。它与 overview 的 `quoteProblemCount` 使用相同估值路径，前端不得再用直连汇率自行推断多跳路径是否缺失。
- 最新估值刷新可显式配置 `FINWEALTH_QUOTE_PROVIDER=public`：BTC/ETH/USDT 使用 CoinGecko，其他已登记且以 USDT 计价的 crypto 标的使用 OKX 公共现货 ticker，传统法币 FX 使用 Frankfurter/ECB；默认 `none` 不联网。结构化 lookup 只读，Agent 仍须把结果提交为待审核报价候选，采用前不改变估值。`public` 不提供历史行情，历史价格仍只在 Yahoo provider 下可用。
- 固定收益条款配置在具体 holding 上，包含明确本金、年利率、起息/到期日、360/365 日计数、单利或月/季/年复利及收款账户。`yield-positions` 返回截至指定日期的应计收益；`interest-proposals` 固化本期计算依据并进入既有审核队列，确认前不增加余额，确认后才推进累计截止日。
- 贷款条款配置在负债 account 上。`liability-positions` 按当前负余额计算未偿本金、应计利息及下一期计划金额的预计本金/利息拆分；`repayment-schedule` 从当前债务逐月投影，使用每期真实间隔天数，支持负摊销、到期气球款和 1–360 条分页；`loan-interest-proposals` 只生成待审核利息；`loan-payment-proposals` 将付款日前利息与实际还款组成同一审核组，确认后原子更新付款余额、债务、计息截止日与下次还款日。浮动利率只使用用户当前维护的年利率，不自动调用外部基准。

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
- 所有分录币种必须在对应账户的 `supportedCurrencies` 中；带 `instrumentId` 的分录只允许进入 `holdings` / `mixed` 账户。
- `income` / `dividend` / `interest` 当前为单现金分录 `in/source`；`expense` / `fee` 当前为单现金分录 `out/source`；普通 `adjustment` 为单现金 `adjustment` 分录。带 instrument 的 adjustment 只能由持仓调整入口生成。
- `buy` / `sell` 必须包含一条 principal 现金腿和一条带 `instrumentId` 的数量持仓腿，
  可额外包含 `role=fee|tax` 的现金 `out` 腿。费用腿必须与 principal 现金腿使用同一账户、
  同一币种，不允许把费用混入持仓数量。
- 买入 principal 为现金 `out/source`，持仓为 `in/destination`；现金减少
  `principal + fee + tax`，同一总额增加 `costBasisTotal`。
- 卖出持仓为 `out/source`，principal 为现金 `in/destination`；现金增加
  `gross proceeds - fee - tax`，费用/税费总额不得超过 gross proceeds；成本基础仍按出售
  数量比例减少。报价后按 `quantity × price` 估值。
- sell 确认后 movement 增加只读 `saleResult`。服务端按平均成本法固化
  `costBasisReleased`；同币种时计算 `realizedPnl = netProceeds - costBasisReleased`，成本
  未知时标记 `cost_basis_unavailable`。跨币种时只使用不晚于 `occurredAt` 的最近 FX rate，
  固化 `fxBasis` 并标记 `calculated_with_fx`；无历史 rate 时标记 `currency_mismatch`。
- 跨币种买入叠加既有成本基础时也使用同一历史选择规则，所用 rate 固化为 `costBasisFx`；
  不得因用户稍后确认一笔旧成交而使用确认当天的新汇率。
- `loan_disbursement` 必须从负债账户 `out/source` 到非负债账户 `in/destination`；`loan_repayment` 方向相反；两腿同币种同金额且账户不同。
- 普通 draft 不接受 `type=correction`；更正只能通过 `/v1/movements/corrections` 创建，避免绕过原记录引用与反向分录。
- 投资 movement 更正必须提交完整 `replacementEntries`，不接受只给金额 diff。当前只允许更正
  同一持仓最后一笔已确认的 buy/sell：确认时先按原成交固化的现金、数量、成本基础精确撤销，
  再以原 `occurredAt` 应用完整 replacement。若该持仓已有后续已确认成交、目标已被更正，或旧
  sell 缺少 `saleResult.costBasisReleased`，返回 409，不猜测历史成本。
- correction 兼容单分录 `proposedDiffs`，也可提交完整 `replacementEntries` 更正多腿交易。
- 多腿更正会在同一个 pending correction movement 中逐腿反向原分录并写入完整替换分录；确认前不影响余额，确认时整组原子应用，原 confirmed movement 永不改写。
- `replacementEntries` 是完整目标状态而非局部 patch；完全不改变分录语义或账本效果的
  replacement 返回 400，同一原记录已有 pending correction 时返回 409。投资成交即使净现金
  与数量不变，只要 principal/fee/tax 构成变化，仍属于有效 replacement。
- 投资 replacement 的派生结果保存在 correction movement 的 `investmentReplacement` 中；原
  buy/sell movement、原 entries、原 `saleResult` 均保持不可变。

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

- `mark-executed-as-proposal` 必须提交真实成交输入：持仓账户、实际成交数量、实际总成本、
  标的报价币种，以及可选成交时间。计划金额只用于提醒或前端默认值，不得兼作成交数量。
- 资金账户沿用 DCA plan 的 `fundingAccountId`，必须支持 `totalCost.currency`；持仓账户必须是
  未归档的 `holdings` / `mixed` 账户并支持 `quoteCurrency`。已存在标的的报价币种必须一致。
- 生成的 buy 候选中，现金腿金额等于 `totalCost.amount`，持仓腿金额等于 `quantity`。
- 同一 reminder 同时最多存在一个 `pending_review` 候选；同幂等键重放原响应，不同幂等键
  重复创建返回冲突。
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
POST  /v1/subscriptions/charge-proposals/due-scan
```

订阅用于管理 ChatGPT Plus、Claude Pro 等周期性服务费用：

- 金额始终保存原币种，不因首页本位币估值而改写原始订阅金额。
- `billingCycle` 支持日、周、自然月、自然年及正整数间隔。
- 自然月/年保留最初扣款日作为 `billingAnchorDay`；31 日遇短月取月末，后续月份恢复锚点，不永久漂移到 28 日。
- 创建时可提供 `duration` 或 `endDate`，二者互斥；不提供表示持续订阅。
- PATCH 将 nullable `duration`/`endDate` 视为一组排期替换字段：二者都非空时冲突；`duration` 非空时按 `startDate` 计算 `endDate`；仅 `endDate` 非空时移除 `duration`；两者都为 `null` 时清除有限期限。
- 创建和 PATCH 都以修改后的完整 subscription 做付款校验：`paymentAccountId` 必须引用未归档账户，且账户 `supportedCurrencies` 必须包含 `amount.currency`；校验失败时不保留部分修改。
- subscription 计划本身不写支出。`charge-proposal` 只创建 `pending_review` expense，确认 atomic group 后才影响账户余额并推进 `nextChargeDate`；拒绝后允许重新生成同一期候选。
- 单条 `charge-proposal` 在真正生成候选前再次校验付款账户和币种。若账户后来被归档或支持币种发生漂移，后端拒绝生成，不换算原金额、不改写计划币种。
- `due-scan` 请求体只允许 `throughDate`（必填 ISO date）和 `limit`（默认 100，范围 1–200）；未知字段返回 400。它只扫描 `trial|active` 且 `nextChargeDate <= throughDate` 的计划，并按 `(nextChargeDate, id)` 稳定排序。
- `limit` 只限制本次新建候选数量，不限制检查或报告 skip。已有 pending 的项目以 `already_pending` 跳过；付款账户缺失/已归档以 `payment_account_unavailable` 跳过；账户不支持订阅币种以 `payment_currency_unsupported` 跳过。skip 不阻断其他订阅。
- `due-scan` 返回 `createdCount`、`alreadyPendingCount`、`blockedCount`、`remainingEligibleCount`、`hasMore`、`created[]`、`skipped[]`。`remainingEligibleCount` 只统计因达到 limit 而尚未创建、除此之外可创建的项目；`hasMore` 等价于该值大于 0。
- 一次 `due-scan` 在同一次账本 read-modify-write 中创建全部返回候选、更新 pending 指针并保存幂等响应；任一非预期不变量错误使整批失败。它是显式调用命令，不是后台 timer，不会自动确认、扣款或推进日期。
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
- 文本与图片整理 provider 默认关闭。显式设置 `FINWEALTH_AI_PROVIDER=openai_responses` 后，服务端使用 Responses API Structured Outputs；请求固定 `store=false`，只发送当前输入和最小账户选择上下文。模型输出仍由服务端重新校验账户、币种、正金额、时间和 movement 方向。
- 图片请求体使用 `fileName`、`mimeType`、`imageBase64`；仅接受 PNG、JPEG、WEBP，解码后不超过 10 MiB。服务端校验 Base64、MIME 与文件头；原始图片不写入账本、响应、evidence 摘要或日志。
- provider 配置要求 `FINWEALTH_AI_MODEL`、`FINWEALTH_AI_API_KEY`，`FINWEALTH_AI_BASE_URL` 默认官方 `/v1`，只允许 HTTPS 或回环 HTTP。API key 不写账本、不进入响应、不进入日志。
- provider refusal、incomplete、非 2xx、非法 JSON 或 schema/账本校验失败都 fail closed，不创建可确认 movement；幂等重放必须在联网前返回已保存结果。
- `movements` 中按 atomic group 持久化的 standalone `pending_review` 候选会动态投影到 pending AI Review；投影 ID 为 `proposal_movement_{movementId}`，不会在 `aiProposals` 中再保存一份副本。
- 该投影支持查询、确认和拒绝；standalone 候选不可原地编辑，编辑请求返回冲突，调用方应拒绝后重新生成。确认或拒绝后它从 pending 列表和 pending count 中消失。

## 9. Quotes / FX / Historical Prices

```http
GET  /v1/quotes/summary
GET  /v1/quotes
GET  /v1/fx-rates
POST /v1/quotes/lookup
POST /v1/quotes/refresh
GET  /v1/instruments/{instrumentId}/historical-prices?from=YYYY-MM-DD&to=YYYY-MM-DD
```

规则：

- `lookup` 只调用显式配置的结构化 provider 并返回结果，不写账本、不改变估值，也不要求 `Idempotency-Key`。
- Agent 对报价或汇率请求必须先走 `lookup`；成功结果和后续网页兜底结果都只保存为待审核候选，用户采用后才可调用 `refresh` 写入。
- 只有 `lookup` 对同一目标明确无结果或失败后，Agent 才可使用网页来源；不得跳过确定性来源。
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
- `POST /v1/sync/push` 当前只接受认证设备的 `account/create`：Bearer token 决定 device ID，请求体和每条 change 不得冒充其他设备；无认证开发模式固定为 `dev_unauthenticated_device`。
- 入站 change 必须有 `baseVersion: 0`、完整 Account payload 且 `payload.id == entityId`。账户与远端 sync log 原子提交，响应通过 `acceptedChangeIds`、`appliedChangeIds`、`skippedChangeIds` 区分接收、应用和重放。
- 远端 change 不进入 `pendingChangeIds`。相同 `(sourceDeviceId, sourceChangeId)` 只应用一次；已存在 account ID 返回结构化 manual conflict，不覆盖、不落远端日志。
- 暂不做 account update、movement merge、quote/snapshot/AI proposal 同步、自动冲突解决或 E2EE。

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
