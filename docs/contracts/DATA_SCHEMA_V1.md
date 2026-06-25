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
type DecimalString = string;   // 任意精度十进制字符串
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
- `loan` / `credit_card` / `liability` 语义账户为负数是正常负债。
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
- 时间加权收益、区间收益、现金流归因暂缓。

## 4. LiabilityTerms

负债本身仍通过 Account 表示；贷款条款挂在账户上。

```ts
LiabilityTerms {
  id: ID;
  accountId: ID;
  liabilityType:
    | "student_loan"
    | "mortgage"
    | "consumer_loan"
    | "credit_card"
    | "other";
  principal?: Money;
  interestRateAnnual?: DecimalString;
  rateType?: "fixed" | "floating" | "unknown";
  interestStartDate?: ISODate;
  subsidyEndDate?: ISODate;
  repaymentStartDate?: ISODate;
  nextDueDate?: ISODate;
  repaymentRuleNote?: string;
}
```

规则：

- 助学贷款可展示贴息期、计息开始时间、还款开始时间。
- MVP 不自动计算复杂摊销表。
- 未经用户确认的贷款利率规则不得自动写入正式账本。

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
```

规则：

- `atomicGroupId` 是确认、拒绝、回滚的最小单位。
- 多腿交易必须整组接受或整组拒绝。
- `pending_review` / `draft` 不影响正式余额和净值。
- 已确认记录原则上不原地改写；更正优先通过 `correction` 事件表达。

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
```

UI 动作：

- `记录已执行`：只生成待确认 Movement proposal。
- `跳过本期`：记录提醒状态，不生成交易。
- `稍后提醒`：snooze。

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

