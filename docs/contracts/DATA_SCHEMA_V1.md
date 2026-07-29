# DATA_SCHEMA_V1

状态：草案冻结给前端使用。  
用途：作为 Flutter Repository / ViewModel / 本地账本 / AI proposal / 同步层之间的共同领域语言。  
非用途：不是数据库迁移脚本，不决定 SQLite/Drift/Rust 的最终表结构。

## 0. 设计原则

1. 本产品是个人资产 / 投资 / 负债控制台，不是普通记账 App。
2. 已确认数据与候选数据必须分离。
3. AI、导入、定投提醒只能生成候选记录；用户确认后才进入正式账本。
4. 自动转账、自动下单、投资建议不属于本 schema。
5. 金额、数量、价格、汇率统一用十进制字符串，禁止用浮点数保存。
6. 消费记录只解释资产变化；优惠券/免单券只是交易金额拆分字段，不是功能模块。
7. 负债与资产分列展示；负债账户余额为负不是异常。
8. 所有估值必须带时间口径与质量口径。

## 1. 基础类型

```ts
type ID = string;              // UUID/ULID，具体算法由实现层决定
type ISODate = string;         // YYYY-MM-DD
type ISODateTime = string;     // ISO 8601 with timezone
type DecimalString = string;   // 定点十进制字符串，当前最多 8 位小数
type CurrencyCode = string;    // CNY/USD/HKD/USDT/BTC/ETH 等
```

```ts
Money {
  amount: DecimalString;
  currency: CurrencyCode;
}

ValuedMoney {
  amount: DecimalString;
  currency: CurrencyCode;
  asOf: ISODateTime;
  quality: ValueQuality;
}

ValueQuality =
  | "exact"
  | "estimated"
  | "incomplete"
  | "unpriceable"
  | "anomaly";

QuoteStatus =
  | "fresh"
  | "stale"
  | "offline_cached"
  | "incomplete"
  | "unpriceable"
  | "error";
```

规则：

- `0` 是有效数值，`null` / 缺字段才表示未知。
- `unpriceable` 不得按 0 计入净值。
- `estimated` 必须在 UI 中显示 `≈` 或等价提示。

## 2. Account

账户是资产、负债、钱包、券商、交易所、平台余额等容器。

```ts
Account {
  id: ID;
  displayName: string;
  institutionName?: string;
  accountType: AccountType;
  defaultCurrency: CurrencyCode;
  supportedCurrencies: CurrencyCode[];
  includeInNetWorth: boolean;
  visibility: "normal" | "hidden_amount" | "archived";
  status: "active" | "inactive" | "archived";
  balanceMode: "cash_balance" | "holdings" | "liability" | "mixed";
  cashBalances: AccountCashBalance[];
  tags: string[];
  note?: string;
  createdAt: ISODateTime;
  updatedAt: ISODateTime;
}

AccountType =
  | "bank"
  | "brokerage"
  | "exchange"
  | "wallet"
  | "platform_wallet"
  | "virtual_card"
  | "social_security"
  | "credit_card"
  | "loan"
  | "cash"
  | "other";

AccountCashBalance {
  currency: CurrencyCode;
  amount: DecimalString;
  asOf: ISODateTime;
  quality: ValueQuality;
}
```

规则：

- 多币种账户用 `cashBalances[]` 表示。
- 用户也可以主动拆成多个账户，但系统不得为了币种自动伪造账户。
- `loan` / `credit_card` / `liability` 语义账户为负数是正常负债；正余额（例如信用卡
  溢缴款）仍保持资产语义，不得按绝对值计入负债。
- `bank` / `wallet` / `cash` 等资产账户出现负数才可能触发 `negative_balance` 异常。

## 3. Instrument 与 Holding

`Instrument` 表示资产标的。  
`Holding` 表示某个账户持有某个标的的数量。

```ts
Instrument {
  id: ID;
  type: InstrumentType;
  symbol?: string;
  displayName: string;
  quoteCurrency: CurrencyCode;
  market?: string;        // US/HK/CN/CRYPTO 等
  sourceRef?: string;
}

InstrumentType =
  | "cash"
  | "equity"
  | "fund"
  | "crypto"
  | "fx_cash"
  | "receivable"
  | "other";

Holding {
  id: ID;
  accountId: ID;
  instrumentId: ID;
  quantity: DecimalString;
  costBasisTotal?: Money;
  marketValue?: ValuedMoney;
  accountMarketValue?: ValuedMoney; // 按所属账户 defaultCurrency 折算；账户详情合计使用
  dayChange?: Money;
  unrealizedPnl?: Money;
  unrealizedPnlRate?: DecimalString;
  quoteStatus: QuoteStatus;
  asOf: ISODateTime;
  note?: string;
}
```

规则：

- “主要持仓”默认按市值占比排序，不按收益率排序。
- 成本未知时显示“成本未记录”，不得伪造成本。
- `unpriceable` 时市值显示 `—`，不按 0 参与净值。
- MVP 收益率口径：
  - `unrealizedPnl = marketValue - costBasisTotal`
  - `unrealizedPnlRate = unrealizedPnl / costBasisTotal`
- 只有 `marketValue` 与 `costBasisTotal` 币种一致时才计算未实现盈亏；缺少历史成交 FX 时
  不使用不同币种的裸数字相减，也不伪造换算后的成本。
- 时间加权收益、区间收益、现金流归因暂缓。

## 3A. 固定收益持仓条款

利率条款属于具体 Holding，而不是全局 Instrument；同一产品在不同账户可以有不同本金、起息日和到期日。

```ts
YieldTerms {
  principal: Money;
  annualRate: DecimalString;
  rateType: "fixed" | "floating";
  interestMethod: "simple" | "compound";
  dayCountBasis: 360 | 365;
  compoundingFrequency: "none" | "monthly" | "quarterly" | "annual";
  interestStartDate: ISODate;
  maturityDate: ISODate;
  payoutAccountId: ID;
  lastAccruedThrough: ISODate;
  pendingInterestMovementId?: ID;
}
```

- simple 使用实际天数 / dayCountBasis；compound 对完整月/季/年周期复利，剩余天数按当前复合余额进行日比例计提。
- 应计收益是派生读模型，不直接改变余额。
- 生成利息后只创建 `pending_review` interest movement；确认后才增加收款账户余额并推进 `lastAccruedThrough`。
- 每个持仓同时最多一个待确认利息 movement；存在 pending 时不得修改条款。
- 已确认 movement 固化当期本金、年利率、计息方式、天数和利息金额；后续修改条款不得改写历史。

`YieldAccrual` 固化 holding、上次/本次截止日、本金、利率、计息方式、日基准、复利周期、天数和本期利息。

## 4. LiabilityTerms

负债本身仍通过 Account 表示；贷款条款挂在账户上。

```ts
LiabilityTerms {
  liabilityType:
    | "student_loan"
    | "mortgage"
    | "consumer_loan"
    | "credit_card"
    | "other";
  annualRate: DecimalString;
  rateType: "fixed" | "floating";
  dayCountBasis: 360 | 365;
  interestStartDate: ISODate;
  maturityDate: ISODate;
  repaymentStartDate: ISODate;
  nextDueDate: ISODate;
  repaymentFrequency: "monthly";
  repaymentAnchorDay: 1..31;
  scheduledPayment: Money;
  paymentAccountId: ID;
  lastInterestAccruedThrough: ISODate;
  pendingLoanInterestMovementId?: ID;
  pendingLoanPaymentMovementId?: ID;
}
```

规则：

- 未偿本金来自负债账户当前负余额的绝对值，不另存一份会漂移的本金。
- 简单利息按未偿本金、年利率、实际天数及 360/365 基准计算；读模型给出截至日期的应计利息和下一期计划金额的预计本金/利息拆分。
- `scheduledPayment` 是用户录入的合同计划金额，不由服务端猜测等额本息或复杂摊销规则。
- 多期还款表从当前未偿债务开始，逐月按真实间隔天数计算；计划金额不足当期利息时未付利息进入期末债务，到期日用气球款结清投影余额。它是基于现有条款的前瞻读模型，不改写账本。
- 生成贷款利息只创建 `pending_review` movement；确认后才增加负债并推进累计截止日，拒绝不改变余额。
- 还款候选把付款日前新增利息和 `loan_repayment` 放在同一 atomic group；确认同时扣付款账户、减少债务并推进计息截止日和 `nextDueDate`。付款先覆盖当期利息，剩余部分减少本金；不足覆盖的利息保留在债务余额中。
- 浮动利率由用户在每个计息区间前维护当前年利率；movement 固化当期利率，不假装自动跟踪 LPR 等外部基准。

`LoanInterestAccrual` 固化负债 account、上次/本次截止日、计算时未偿金额、利率类型、年利率、日基准、天数和本期利息。`LoanPayment` 固化付款账户、还款日、付款额、本金/利息拆分、未付利息和前后到期日。

## 5. Movement

`Movement` 是资产变化事件。收入、支出、转账、买卖、分红、利息、费用、校正都属于 Movement。

```ts
Movement {
  id: ID;
  atomicGroupId: ID;
  type: MovementType;
  occurredAt: ISODateTime;
  recordedAt: ISODateTime;
  status: MovementStatus;
  title: string;
  description?: string;
  entries: MovementEntry[];
  categoryId?: ID;
  counterpartyId?: ID;
  tags: string[];
  amountBreakdown?: TransactionAmountBreakdown;
  settlement?: SettlementInfo;
  transferMeta?: TransferMeta;
  saleResult?: InvestmentSaleResult;
  costBasisFx?: ExecutionFxBasis;
  investmentReplacement?: InvestmentReplacement;
  yieldAccrual?: YieldAccrual;
  loanInterestAccrual?: LoanInterestAccrual;
  subscriptionId?: ID;
  scheduledChargeDate?: ISODate;
  source: DataSourceInfo;
  createdAt: ISODateTime;
  updatedAt: ISODateTime;
}

MovementType =
  | "income"
  | "expense"
  | "transfer"
  | "buy"
  | "sell"
  | "dividend"
  | "interest"
  | "fee"
  | "adjustment"
  | "loan_disbursement"
  | "loan_repayment"
  | "loan_interest"
  | "correction";

MovementStatus =
  | "draft"
  | "pending_review"
  | "confirmed"
  | "in_transit"
  | "cancelled"
  | "reversed";

MovementEntry {
  id: ID;
  accountId: ID;
  instrumentId?: ID;
  amount: DecimalString;
  currency: CurrencyCode;
  direction: "in" | "out";
  role:
    | "source"
    | "destination"
    | "fee"
    | "discount"
    | "pnl"
    | "tax"
    | "adjustment";
}

InvestmentSaleResult {
  costBasisMethod: "average_cost";
  grossProceeds: Money;
  feeAndTaxTotal: Money;
  netProceeds: Money;
  costBasisReleased?: Money;
  netProceedsInCostBasisCurrency?: Money;
  realizedPnl?: Money;
  fxBasis?: ExecutionFxBasis;
  realizedPnlStatus:
    | "calculated"
    | "calculated_with_fx"
    | "cost_basis_unavailable"
    | "currency_mismatch";
}

ExecutionFxBasis {
  baseCurrency: CurrencyCode;
  quoteCurrency: CurrencyCode;
  rate: DecimalString;
  asOf: ISODateTime;
  sourceRateId: ID;
  source: string;
  sourceUrl?: string;
  inverted: boolean;
}

InvestmentReplacement {
  targetType: "buy" | "sell";
  targetOccurredAt: ISODateTime;
  replacementEntries: MovementEntry[];
  saleResult?: InvestmentSaleResult;
  costBasisFx?: ExecutionFxBasis;
}
```

规则：

- `atomicGroupId` 是确认、拒绝、回滚的最小单位。
- 多腿交易必须整组接受或整组拒绝。
- `pending_review` / `draft` 不影响正式余额和净值。
- subscription 扣费候选必须同时带 `subscriptionId` 与 `scheduledChargeDate`，并与 subscription 上的 pending 指针双向一致。
- 已确认记录原则上不原地改写；更正优先通过 `correction` 事件表达。
- 当前 server mode 不把 `MovementType` 仅当展示标签：收入类、支出类、余额校准、买卖、
  贷款放款/还款均有固定分录方向和角色约束；不符合类型语义的 draft 在写入前返回 400。
- `buy` / `sell` 的 principal 现金腿表示不含费用的成交价款，持仓腿表示数量；可追加
  `role=fee|tax` 的同账户、同币种现金 `out` 腿。
- 买入现金实际流出与成本基础增加额均为 `principal + fee + tax`；卖出现金实际流入为
  `gross proceeds - fee - tax`，成本基础按出售数量比例减少。费用不得混入数量，卖出费用
  总额不得超过 gross proceeds。报价估值仍使用 `quantity × price`。
- sell 确认时服务端固化 `saleResult`：平均成本法释放本次成本，`netProceeds =
  grossProceeds - feeAndTaxTotal`。只有净回款与释放成本同币种时才写 `realizedPnl =
  netProceeds - costBasisReleased`。跨币种时只允许使用 `asOf <= occurredAt` 的最近历史
  FX；找到时固化 `fxBasis` 并计算，找不到时写明确状态，不伪造数字。
- 已有持仓的买入成本币种不一致时，同样按成交时间选择历史 FX，并把实际换算依据固化到
  `costBasisFx`；不得用确认当天的新汇率回算历史成交。
- `investmentReplacement` 只允许出现在 correction movement，保存被替代成交类型、原成交
  时间、完整 replacement entries，以及确认后重新派生的 `saleResult` / `costBasisFx`。投资
  更正只作用于同一持仓最后一笔已确认成交，旧 sell 没有固化释放成本时不得猜测更正。

## 6. Transfer / 在途 / 折损

转账是 `Movement.type = "transfer"` 的特例。

```ts
SettlementInfo {
  status: "settled" | "in_transit" | "failed" | "unknown";
  expectedSettleAt?: ISODateTime;
  expectedDelayHours?: number;
  settledAt?: ISODateTime;
}

TransferMeta {
  fromAccountId: ID;
  toAccountId: ID;
  fromAmount: Money;
  toAmount?: Money;
  feeAmount?: Money;
  lossAmount?: Money;
  fxRate?: DecimalString;
  note?: string;
}
```

规则：

- 缺省 `settlement.status = "settled"`。
- 用户口述“几小时后到账”时写入 `expectedDelayHours`。
- 汇损、滑点、平台折损写入 `lossAmount` 或 `feeAmount`。
- 在途交易进入首页待处理区，不作为消费展示。
- schema 保留跨币种、手续费和汇损字段，但当前 server mode 只实现同币种同额双分录；
  未实现的 transfer shape 必须明确拒绝，不得按普通分录直接落账。

## 7. TransactionAmountBreakdown

优惠券、免单、补贴只解释交易金额，不是功能模块。

```ts
TransactionAmountBreakdown {
  grossAmount?: Money;
  savingsAmount?: Money;
  paidAmount: Money;
  benefitSource?:
    | "coupon"
    | "platform_subsidy"
    | "merchant_discount"
    | "free_order"
    | "other";
}
```

规则：

- `savingsAmount` 不是收入。
- 不做优惠券列表、过期提醒、省钱排行、奶茶规划。
- 首页不以优惠券或消费为主角。

## 8. Category 与 Counterparty

分类可预置、可自定义；对手方不做穷举目录。

```ts
Category {
  id: ID;
  displayName: string;
  parentId?: ID;
  kind:
    | "income"
    | "expense"
    | "transfer"
    | "investment"
    | "liability"
    | "system";
  isSystem: boolean;
  aiDescription?: string;
}

Counterparty {
  id: ID;
  displayName: string;
  aliases: string[];
  normalizedName?: string;
  categoryHintId?: ID;
  isUserMerged: boolean;
}
```

规则：

- “瑞幸咖啡”可以是 Counterparty。
- “咖啡”更像 Category/Tag，不应自动归并到瑞幸。
- AI 可以提出合并建议，用户确认后才合并。
- Category ID 必须唯一；`displayName` 非空，`parentId` 必须引用现有分类且分类树不得自指或成环。
- Counterparty ID 必须唯一；`displayName` 和 alias 不得为空，规范化名称存在时不得为空，单个对手方的 alias 不得重复。
- `categoryHintId` 存在时必须引用现有 Category；删除或修改分类不得留下悬空提示。

## 9. DCA Plan

定投只提醒与记录，不下单。

```ts
DcaPlan {
  id: ID;
  displayName: string;
  targetInstrumentId: ID;
  fundingAccountId?: ID;
  plannedAmount: Money;
  frequency: "weekly" | "monthly" | "custom";
  nextDueDate: ISODate;
  reminderStatus: "active" | "snoozed" | "paused" | "completed";
  lastActionAt?: ISODateTime;
  note?: string;
}

DcaReminder {
  id: ID;
  planId: ID;
  dueDate: ISODate;
  status: "due" | "overdue" | "snoozed" | "recorded" | "skipped";
}

DcaExecutionInput {
  holdingAccountId: ID;
  quantity: DecimalString;      // 实际成交数量，必须 > 0
  totalCost: Money;             // 实际总成本，amount 必须 > 0
  quoteCurrency: CurrencyCode;  // 标的报价币种
  executedAt?: ISODateTime;     // 缺省为服务端当前时间
}
```

`plannedAmount` 只表达计划投入额，不是成交数量。记录执行时，现金腿使用
`totalCost.amount`，持仓腿使用 `quantity`；两者不得复用同一个字段。

UI 动作：

- `记录已执行`：只生成待确认 Movement proposal / draft；可持久化等待复核，但确认前不影响 confirmed/effective ledger。
- `跳过本期`：记录提醒状态，不生成交易。
- `稍后提醒`：snooze。

## 9A. Subscription

订阅计划描述未来的周期性付款；它本身不是已发生的账本交易。

```ts
SubscriptionBillingCycle {
  unit: "day" | "week" | "month" | "year";
  interval: number;
}

SubscriptionDuration {
  unit: "day" | "month" | "year";
  count: number;
}

Subscription {
  id: ID;
  displayName: string;
  provider: string;
  planName?: string;
  amount: Money;
  paymentAccountId: ID;
  billingCycle: SubscriptionBillingCycle;
  billingAnchorDay: number;
  startDate: ISODate;
  duration?: SubscriptionDuration;
  endDate?: ISODate;
  nextChargeDate?: ISODate;
  autoRenew: boolean;
  reminderDaysBefore: number;
  status: "trial" | "active" | "paused" | "cancelled" | "expired";
  pendingChargeMovementId?: ID;
  pendingChargeDate?: ISODate;
  lastChargeDate?: ISODate;
  lastChargeMovementId?: ID;
  note?: string;
  createdAt: ISODateTime;
  updatedAt: ISODateTime;
}

SubscriptionDueScanInput {
  throughDate: ISODate;
  limit?: number; // default 100, range 1..200
}

SubscriptionDueScanSkipReason =
  | "already_pending"
  | "payment_account_unavailable"
  | "payment_currency_unsupported";

SubscriptionDueScanSkip {
  subscriptionId: ID;
  scheduledChargeDate: ISODate;
  reason: SubscriptionDueScanSkipReason;
}

SubscriptionDueScanResult {
  throughDate: ISODate;
  createdCount: number;
  alreadyPendingCount: number;
  blockedCount: number;
  remainingEligibleCount: number;
  hasMore: boolean;
  created: (AiAtomicGroup & {
    subscriptionId: ID;
    scheduledChargeDate: ISODate;
  })[];
  skipped: SubscriptionDueScanSkip[];
}
```

规则：

- `amount` 保留订阅原币种（如 USD），不得在计划层静默换算为本位币。
- `paymentAccountId` 必须引用未归档账户，且该账户必须显式支持 `amount.currency`；创建和 PATCH 以修改后的完整对象校验，失败时原对象保持不变。
- 账户后续被归档或移除支持币种属于付款能力漂移，不会反向改写既有 subscription。生成候选时必须重新校验；单条生成返回错误，批量扫描分别报告 `payment_account_unavailable` 或 `payment_currency_unsupported`。
- `duration` 与 `endDate` 二选一；固定终止日期优先于 `autoRenew`，到期后必须显式延长。
- `startDate` 是订阅计划开始日期，`nextChargeDate` 是下一次实际扣费日期，两者不得在 UI 中混为一个字段。PATCH 仅修改 `startDate` 且旧 `nextChargeDate` 已早于新开始日期时，服务端将后者安全推进到新开始日期。
- 月度和年度周期以 `billingAnchorDay` 为锚点；短月份可落在月末，后续月份恢复原锚点。
- 到期提醒只生成 `pending_review` 支出候选；确认前不影响账户余额。
- 同一订阅、同一计费日期最多存在一个待确认扣费候选。
- `pendingChargeMovementId` 与 `pendingChargeDate` 必须成对出现，并引用存在的 `pending_review` movement；movement 的 `subscriptionId`、`scheduledChargeDate` 必须反向匹配。孤立的 pending subscription movement 或重复 pending 键均为无效账本。
- 候选确认后才推进 `nextChargeDate`；拒绝后保持原计费日期，可重新生成候选。
- 取消保留历史扣费，但清空未来计费日期；存在待确认扣费时必须先处理候选。
- due scan 只选择 `trial|active` 且 `nextChargeDate <= throughDate` 的计划，按 `(nextChargeDate,id)` 排序。limit 只限制 `created`；`remainingEligibleCount` 不包含已 pending 或付款能力受阻的项目，`hasMore = remainingEligibleCount > 0`。

## 10. Quote / FXRate

```ts
Quote {
  id: ID;
  instrumentId: ID;
  price: DecimalString;
  currency: CurrencyCode;
  asOf: ISODateTime;
  expiresAt?: ISODateTime;
  source: string;
  status: QuoteStatus;
}

FXRate {
  id: ID;
  baseCurrency: CurrencyCode;
  quoteCurrency: CurrencyCode;
  rate: DecimalString;
  asOf: ISODateTime;
  expiresAt?: ISODateTime;
  source: string;
  status: QuoteStatus;
}
```

刷新模式：

- `manual`
- `startup`
- `scheduled`

规则：

- Quote ID 必须唯一；每个 instrument 在当前 `quotes[]` 中最多保存一条当前报价。
- `instrumentId` 必须引用现有 Instrument，`currency` 必须等于该标的的 `quoteCurrency`，`price` 必须为正 decimal string。
- `asOf` / `expiresAt` 必须是 RFC3339，`source` 非空，`status` 必须属于 `QuoteStatus`。
- 修改 Instrument 的 `quoteCurrency` 时必须同时满足现有报价和带该 `instrumentId` 的 movement entry 币种一致；不允许留下历史引用冲突。
- 断网时保留上次报价/汇率，标为 `offline_cached` 或 `stale`。
- 使用缓存估值时净值质量为 `estimated`，UI 显示 `≈` 和 as-of。
- 无法估值时不得按 0 计入。

## 11. Snapshot

```ts
NetWorthSnapshot {
  id: ID;
  snapshotAt: ISODateTime;
  baseCurrency: CurrencyCode;
  grossAssets: Money;
  totalLiabilities: Money;
  netWorth: Money;
  quality: ValueQuality;
  quoteStatusSummary: QuoteStatusSummary;
  accountValues: AccountValueSnapshot[];
}

QuoteStatusSummary {
  freshCount: number;
  staleCount: number;
  unpriceableCount: number;
  errorCount: number;
}

AccountValueSnapshot {
  accountId: ID;
  value: ValuedMoney;
}
```

规则：

- 首页默认显示“较上次快照”。
- 只有全量估值 fresh 时才允许显示“今日涨跌”。
- 快照是概览二级能力，不是一级导航。

## 12. AccountAnomaly

```ts
AccountAnomaly {
  id: ID;
  accountId: ID;
  kind:
    | "quote_stale"
    | "unpriceable"
    | "reconcile_needed"
    | "negative_balance"
    | "data_anomaly";
  severity: "info" | "warning" | "critical";
  detail: string;
  affectedValue?: Money;
  action?: "review" | "refresh" | "reconcile" | "ignore";
  createdAt: ISODateTime;
}
```

规则：

- 异常必须有统一入口。
- 异常不得被折叠到用户看不到。
- 语义色超过预算时聚合为“N 项问题”，但仍可展开。

## 13. DataSourceInfo

```ts
DataSourceInfo {
  kind:
    | "manual"
    | "ai_proposal"
    | "csv_import"
    | "quote_refresh"
    | "sync"
    | "system";
  sourceId?: ID;
  createdBy?: "user" | "ai" | "system";
}
```

## 14. Repository 命名基线

Flutter 第一阶段以这些 Repository 名称为准，正式字段在 `DATA_SCHEMA_V1` 内冻结。

```ts
AccountRepository
PortfolioRepository
MovementRepository
DcaRepository
QuoteRepository
AiProposalRepository
SnapshotRepository
```

旧 `API_CONTRACT_V1.md` 如存在，仅作为 legacy reference，不驱动 UI / Repository 命名。
