# APPLICATION_INTERFACES_V1

状态：草案冻结给并行开发使用。  
用途：定义应用层接口边界，避免 UI、本地账本、同步服务、AI、行情各自发明调用方式。  
非用途：不是 Flutter 页面实现，不是数据库表结构，不绑定具体后端框架。

## 0. 分层边界

```text
UI / Shell
  ↓
Application Interfaces
  ↓
Ledger Core
  ↓
Storage / Quote Provider / AI Provider / Sync Client
```

规则：

- UI 只调用 Application Interfaces。
- Ledger Core 负责账本校验、候选确认、快照计算、debug fixture 隔离。
- Storage 只负责持久化，不负责业务解释。
- AI Provider 只能产出 proposal。
- Quote Provider 只能产出 quote / fx rate / historical price。
- Sync Client 只能同步账本变更，不执行转账或交易。

## 1. 通用返回

```ts
Result<T> =
  | { ok: true; value: T }
  | { ok: false; error: AppError };

AppError {
  code: string;
  message: string;
  severity: "info" | "warning" | "error" | "critical";
  retryable: boolean;
  details?: unknown;
}
```

规则：

- 金额、账户、币种、AI 审批失败必须返回结构化错误。
- 不在错误里输出 token、密码、原始敏感图片内容。

## 2. AccountService

```ts
AccountService {
  listAccounts(): Result<Account[]>;
  getAccount(accountId: ID): Result<Account>;
  createAccount(input: CreateAccountInput): Result<Account>;
  updateAccount(accountId: ID, patch: UpdateAccountPatch): Result<Account>;
  archiveAccount(accountId: ID): Result<Account>;
  listAnomalies(): Result<AccountAnomaly[]>;
}

CreateAccountInput {
  displayName: string;
  institutionName?: string;
  accountType: AccountType;
  defaultCurrency: CurrencyCode;
  supportedCurrencies: CurrencyCode[];
  includeInNetWorth: boolean;
  balanceMode: "cash_balance" | "holdings" | "liability" | "mixed";
  openingBalances?: AccountCashBalance[];
}
```

约束：

- 创建账户不应自动创建虚假资产。
- 多币种账户优先通过 `cashBalances[]` 表达。
- 负债账户的负数余额不触发 `negative_balance`。

## 3. PortfolioService

```ts
PortfolioService {
  getOverview(): Result<PortfolioOverview>;
  listHoldings(filter?: HoldingFilter): Result<Holding[]>;
  listHoldingsByAccount(accountId: ID): Result<Holding[]>;
  getAssetAllocation(): Result<AssetAllocation>;
}

PortfolioOverview {
  latestSnapshot?: NetWorthSnapshot;
  previousSnapshot?: NetWorthSnapshot;
  pendingSummary: PendingSummary;
  quoteStatusSummary: QuoteStatusSummary;
  primaryHoldings: Holding[];
  recentMovements: Movement[];
}

PendingSummary {
  aiPendingCount: number;
  accountAnomalyCount: number;
  dcaDueCount: number;
  inTransitCount: number;
  quoteProblemCount: number;
  syncProblemCount: number;
}
```

约束：

- 首页默认展示“较上次快照”。
- 只有报价与汇率全 fresh 才允许展示“今日涨跌”。
- `quoteProblemCount` 是 stale、offline cached、unpriceable 与 error 估值项数量之和；不得只统计缺失报价，也不得把所有问题统一描述成“本地缓存”。
- `primaryHoldings` 按市值占比排序，不按收益率排序。

## 4. MovementService

```ts
MovementService {
  listMovements(filter?: MovementFilter): Result<Movement[]>;
  getMovement(movementId: ID): Result<Movement>;
  createManualDraft(input: CreateMovementDraftInput): Result<Movement>;
  submitDraftForReview(movementId: ID): Result<AiAtomicGroup>;
  confirmAtomicGroup(atomicGroupId: ID): Result<ConfirmResult>;
  rejectAtomicGroup(atomicGroupId: ID, reason?: string): Result<void>;
  createCorrection(input: CreateCorrectionInput): Result<AiAtomicGroup>;
}

CreateMovementDraftInput {
  type: MovementType;
  occurredAt: ISODateTime;
  title: string;
  entries: MovementEntry[];
  categoryId?: ID;
  counterpartyId?: ID;
  amountBreakdown?: TransactionAmountBreakdown;
  settlement?: SettlementInfo;
  transferMeta?: TransferMeta;
  saleResult?: InvestmentSaleResult; // sell 确认时由服务端生成，客户端不可提交
  costBasisFx?: ExecutionFxBasis;     // 跨币种买入成本换算时由服务端生成
  investmentReplacement?: InvestmentReplacement; // 投资 correction 的完整替代与派生结果
}

ConfirmResult {
  atomicGroupId: ID;
  confirmedMovementIds: ID[];
  ledgerWrite: boolean;
  snapshotInvalidated: boolean;
}
```

约束：

- `confirmAtomicGroup` 是最小写入事务边界。
- `ledgerWrite` 是前端显示“已入账”和刷新账本派生视图的唯一依据。
- draft / pending review 不影响正式余额。
- 已确认记录的修改优先走 correction。
- 当前 server mode 的 `transfer` 只接受两个不同账户间的同币种同金额分录；来源必须
  `out/source`、目标必须 `in/destination`；若提供 `transferMeta`，其中的账户与金额
  必须一致。
- 当前 server mode 同时校验 movement 类型语义：收入类为单现金 `in/source`，支出类
  为单现金 `out/source`，余额校准为单 `adjustment` 分录；买卖由 principal 现金腿、
  数量持仓腿及可选同账户同币种 `fee|tax` 现金流出腿组成。买入费用计入成本基础，卖出
  费用从 gross proceeds 扣除；贷款放款/还款必须在负债账户与非负债账户之间同额流转。
- 每条分录币种必须由账户支持；持仓腿只能进入 `holdings` / `mixed` 账户。普通 draft
  不得直接声明 `correction`，必须走 `createCorrection`。
- 已确认 sell 返回服务端固化的平均成本结果：毛回款、费用税费合计、净回款、释放成本及
  可计算时的已实现盈亏。跨币种按 `occurredAt` 选择历史 FX 并固化依据；无可用历史汇率
  时只返回 `currency_mismatch`。

## 5. DcaService

```ts
DcaService {
  listPlans(): Result<DcaPlan[]>;
  listDueReminders(): Result<DcaReminder[]>;
  createPlan(input: CreateDcaPlanInput): Result<DcaPlan>;
  updatePlan(planId: ID, patch: UpdateDcaPlanPatch): Result<DcaPlan>;
  markExecutedAsProposal(reminderId: ID, input: DcaExecutionInput): Result<AiAtomicGroup>;
  skipReminder(reminderId: ID): Result<DcaReminder>;
  snoozeReminder(reminderId: ID, until: ISODateTime): Result<DcaReminder>;
}

DcaExecutionInput {
  holdingAccountId: ID;
  quantity: DecimalString;
  totalCost: Money;
  quoteCurrency: CurrencyCode;
  executedAt?: ISODateTime;
}
```

约束：

- `markExecutedAsProposal` 只生成候选 Movement。
- `quantity` 是真实成交数量，`totalCost` 是真实现金总成本；不得使用 `plannedAmount.amount`
  同时填充两条分录。
- 资金账户来自 plan，持仓账户来自执行输入；调用方必须让用户确认实际成交数据。
- 不连接券商。
- 不下单。
- 不转账。

## 5A. SubscriptionService

```ts
SubscriptionService {
  listSubscriptions(): Result<Subscription[]>;
  listUpcoming(days?: number): Result<Subscription[]>;
  getSubscription(subscriptionId: ID): Result<Subscription>;
  createSubscription(input: CreateSubscriptionInput): Result<Subscription>;
  updateSubscription(subscriptionId: ID, patch: UpdateSubscriptionPatch): Result<Subscription>;
  cancelSubscription(subscriptionId: ID): Result<Subscription>;
  createChargeProposal(subscriptionId: ID): Result<AiAtomicGroup>;
  scanDueChargeProposals(input: SubscriptionDueScanInput): Result<SubscriptionDueScanResult>;
}

CreateSubscriptionInput {
  displayName: string;
  provider: string;
  planName?: string;
  amount: Money;
  paymentAccountId: ID;
  billingCycle: SubscriptionBillingCycle;
  startDate: ISODate;
  duration?: SubscriptionDuration;
  endDate?: ISODate;
  nextChargeDate?: ISODate;
  autoRenew?: boolean;
  reminderDaysBefore?: number;
  status?: "trial" | "active" | "paused";
  note?: string;
}

UpdateSubscriptionPatch {
  displayName?: string;
  provider?: string;
  planName?: string | null;
  amount?: Money;
  paymentAccountId?: ID;
  billingCycle?: SubscriptionBillingCycle;
  startDate?: ISODate;
  duration?: SubscriptionDuration | null;
  endDate?: ISODate | null;
  nextChargeDate?: ISODate;
  autoRenew?: boolean;
  reminderDaysBefore?: number;
  status?: "trial" | "active" | "paused";
  note?: string | null;
}

SubscriptionDueScanInput {
  throughDate: ISODate;
  limit?: number;
}

SubscriptionDueScanSkipReason =
  | "already_pending"
  | "payment_account_unavailable"
  | "payment_currency_unsupported";

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
  skipped: {
    subscriptionId: ID;
    scheduledChargeDate: ISODate;
    reason: SubscriptionDueScanSkipReason;
  }[];
}
```

约束：

- 订阅计划本身不是已发生的 Movement，不得在创建或编辑计划时扣款。
- `listUpcoming` 默认窗口为 30 天，`days` 只接受 1–365。
- `amount` 保留原币种；`duration` 与 `endDate` 最多一个为非空值。创建/PATCH 后的完整计划必须引用未归档且支持该币种的付款账户，否则原计划保持不变。
- `createChargeProposal` 只生成 `pending_review` 支出候选；同一计费日期不得重复生成候选。
- `scanDueChargeProposals` 的 `throughDate` 必填；limit 默认 100、范围 1–200。它按 `(nextChargeDate,id)` 稳定扫描 active/trial 到期项，limit 只限制 created，已 pending 和付款能力阻塞按 item skip。
- 付款账户后来归档或移除支持币种时，单条和批量生成必须重新校验；不得自动换汇、修改订阅币种或阻断批次中的其他有效计划。
- 候选确认后才写正式流水、影响余额并推进 `nextChargeDate`；拒绝后保留原计费日期。
- 存在待确认扣费候选时取消订阅必须返回冲突；取消不删除历史扣费记录。
- 该服务不连接支付平台，不自动续费或代扣。

## 6. AiProposalService

```ts
AiProposalService {
  createFromText(input: AiTextInput): Result<AiProposal>;
  createFromImage(input: AiImageInput): Result<AiProposal>;
  createFromCsv(input: AiCsvInput): Result<AiProposal>;
  listPending(): Result<AiProposal[]>;
  getProposal(proposalId: ID): Result<AiProposal>;
  approveAtomicGroup(atomicGroupId: ID): Result<ConfirmResult>;
  rejectAtomicGroup(atomicGroupId: ID, reason?: string): Result<void>;
  editAtomicGroup(atomicGroupId: ID, patch: unknown): Result<AiAtomicGroup>;
}

AiTextInput {
  text: string;
  contextScope: "selected_accounts" | "full_ledger";
  selectedAccountIds?: ID[];
}

AiImageInput {
  imageRef: EvidenceRef;
  contextScope: "selected_accounts" | "full_ledger";
  selectedAccountIds?: ID[];
}

AiCsvInput {
  fileRef: EvidenceRef;
  importProfile?: string;
}
```

约束：

- AI service 不写正式账本。
- full ledger context 只用于生成 proposal。
- 修改已有记录必须包含 old → new diff。
- approve 前必须重新校验。
- `listPending` / `getProposal` 同时返回从 standalone `pending_review` movement group 动态生成的只读 proposal；其 ID 为 `proposal_movement_{movementId}`，不要求在 `aiProposals` 中重复保存。
- 这类投影支持 approve/reject；edit 返回冲突，调用方应 reject 后通过原业务命令重新生成。处理后它不再出现在 pending 列表或 `aiPendingCount`。

## 7. QuoteService

```ts
QuoteService {
  getQuoteSummary(): Result<QuoteStatusSummary>;
  listQuotes(): Result<Quote[]>;
  listFxRates(): Result<FXRate[]>;
  refreshQuotes(request: QuoteRefreshRequest): Result<QuoteRefreshResult>;
  getHistoricalPrices(request: HistoricalPriceRequest): Result<HistoricalPricePoint[]>;
}

HistoricalPriceRequest {
  instrumentId: ID;
  from: ISODate;
  to: ISODate;
  maxRange: "one_year";
}
```

约束：

- 第一阶段可返回空/缓存，不发真实请求。
- 接口优先；AI 搜索补全价格时必须附 evidence，用户确认后才可采用。
- `unpriceable` 不得按 0 估值。

## 8. SnapshotService

```ts
SnapshotService {
  getLatest(): Result<NetWorthSnapshot | null>;
  listSnapshots(range: SnapshotRange): Result<NetWorthSnapshot[]>;
  createManualSnapshot(reason: "baseline" | "manual_refresh"): Result<NetWorthSnapshot>;
  invalidateSnapshots(reason: string): Result<void>;
}
```

约束：

- 今天作为基线，不做很久以前的历史补录。
- 快照是概览二级能力，不是一级导航。

## 9. SyncService

```ts
SyncService {
  getStatus(): Result<SyncStatus>;
  bootstrap(): Result<SyncBootstrapResult>;
  pullChanges(cursor?: string): Result<SyncPullResponse>;
  pushChanges(changes: SyncChange[]): Result<SyncPushResult>;
}
```

约束：

- debug fixture 禁止同步。
- 金额、账户、币种冲突默认 manual。
- confirmed Movement 不静默覆盖。

## 10. 禁止出现的接口

这些接口不允许在本产品中出现：

```text
executeTransfer()
placeOrder()
buy()
sellAsBrokerAction()
connectTradingPermission()
autoApproveAiProposal()
autoModifyConfirmedLedger()
planCouponUsage()
recommendMilkTea()
```
