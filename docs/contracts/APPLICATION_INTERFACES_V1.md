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
}

ConfirmResult {
  atomicGroupId: ID;
  confirmedMovementIds: ID[];
  snapshotInvalidated: boolean;
}
```

约束：

- `confirmAtomicGroup` 是最小写入事务边界。
- draft / pending review 不影响正式余额。
- 已确认记录的修改优先走 correction。

## 5. DcaService

```ts
DcaService {
  listPlans(): Result<DcaPlan[]>;
  listDueReminders(): Result<DcaReminder[]>;
  createPlan(input: CreateDcaPlanInput): Result<DcaPlan>;
  updatePlan(planId: ID, patch: UpdateDcaPlanPatch): Result<DcaPlan>;
  markExecutedAsProposal(reminderId: ID): Result<AiAtomicGroup>;
  skipReminder(reminderId: ID): Result<DcaReminder>;
  snoozeReminder(reminderId: ID, until: ISODateTime): Result<DcaReminder>;
}
```

约束：

- `markExecutedAsProposal` 只生成候选 Movement。
- 不连接券商。
- 不下单。
- 不转账。

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

