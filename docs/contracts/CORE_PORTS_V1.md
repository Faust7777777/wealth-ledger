# CORE_PORTS_V1

状态：草案。  
用途：定义本地账本 core 的端口边界，便于后续选择 Rust core / Dart implementation / server implementation。  
非用途：不实现 SQLite、加密、同步、行情、AI，也不改 Flutter UI。

## 0. 设计目标

Ledger Core 是业务真相层，负责：

- 校验领域模型。
- 维护 confirmed ledger。
- 隔离 draft / pending review / debug fixture。
- 确认 atomic group。
- 创建 correction。
- 计算快照输入。
- 暴露稳定接口给 Flutter / Sync / Backend。

Ledger Core 不负责：

- UI 展示。
- 真实行情抓取。
- AI 模型调用。
- VPS HTTP 路由。
- 转账、下单、交易执行。

## 1. 端口总览

```text
Application Services
  ↓
LedgerCore
  ├─ LedgerStorePort
  ├─ ProposalStorePort
  ├─ QuoteStorePort
  ├─ SnapshotStorePort
  ├─ SyncOutboxPort
  ├─ ClockPort
  ├─ IdGeneratorPort
  └─ DecimalPort

External adapters
  ├─ QuoteProviderPort
  ├─ AiProviderPort
  └─ SyncClientPort
```

## 2. LedgerCore facade

```ts
LedgerCore {
  accounts: AccountUseCases;
  portfolio: PortfolioUseCases;
  movements: MovementUseCases;
  dca: DcaUseCases;
  aiProposals: AiProposalUseCases;
  quotes: QuoteUseCases;
  snapshots: SnapshotUseCases;
  sync: SyncUseCases;
}
```

规则：

- facade 不暴露数据库表。
- facade 不暴露 debug fixture 真实路径。
- facade 不包含自动交易接口。

## 3. Store ports

### LedgerStorePort

```ts
LedgerStorePort {
  listAccounts(): Account[];
  getAccount(id: ID): Account | null;
  saveAccount(account: Account): void;

  listInstruments(): Instrument[];
  getInstrument(id: ID): Instrument | null;
  saveInstrument(instrument: Instrument): void;

  listHoldings(filter?: HoldingFilter): Holding[];
  saveHolding(holding: Holding): void;

  listMovements(filter?: MovementFilter): Movement[];
  getMovement(id: ID): Movement | null;
  saveMovementsAtomic(groupId: ID, movements: Movement[]): void;

  listCategories(): Category[];
  saveCategory(category: Category): void;

  listCounterparties(): Counterparty[];
  saveCounterparty(counterparty: Counterparty): void;
}
```

不变量：

- `saveMovementsAtomic` 必须事务化。
- `pending_review` / `draft` 不应被写入 confirmed ledger 视图。
- confirmed movement 不应被静默覆盖。

### ProposalStorePort

```ts
ProposalStorePort {
  listPending(): AiProposal[];
  getProposal(id: ID): AiProposal | null;
  saveProposal(proposal: AiProposal): void;
  updateAtomicGroupStatus(groupId: ID, status: AiAtomicGroupStatus): void;
}
```

不变量：

- proposal store 与 confirmed ledger 分离。
- approve 前必须重新 validation。

### QuoteStorePort

```ts
QuoteStorePort {
  listQuotes(): Quote[];
  saveQuotes(quotes: Quote[]): void;
  listFxRates(): FXRate[];
  saveFxRates(rates: FXRate[]): void;
  getQuoteSummary(): QuoteStatusSummary;
}
```

不变量：

- `unpriceable` 不写成 0。
- 缓存报价必须保留 `asOf` 与 `status`。

### SnapshotStorePort

```ts
SnapshotStorePort {
  getLatest(): NetWorthSnapshot | null;
  listSnapshots(range: SnapshotRange): NetWorthSnapshot[];
  saveSnapshot(snapshot: NetWorthSnapshot): void;
  markInvalid(reason: string): void;
}
```

不变量：

- 写入 confirmed movement 后必须标记快照过期或重新生成。
- 首页默认比较 latest 与 previous。

### SyncOutboxPort

```ts
SyncOutboxPort {
  append(change: SyncChange): void;
  listPending(): SyncChange[];
  markPushed(changeIds: ID[], cursor: string): void;
}
```

不变量：

- debug fixture 禁止进入 outbox。
- token / 密码 / API key 禁止进入 outbox。

## 4. External provider ports

### QuoteProviderPort

```ts
QuoteProviderPort {
  refresh(request: QuoteRefreshRequest): QuoteRefreshResult;
  getHistoricalPrices(request: HistoricalPriceRequest): HistoricalPricePoint[];
}
```

规则：

- 接口优先。
- 如果 provider 无法覆盖，AI/web lookup 只能生成带 evidence 的候选，不直接写入 quote store。

### AiProviderPort

```ts
AiProviderPort {
  proposeFromText(input: AiTextInput, context: AiContext): AiProposal;
  proposeFromImage(input: AiImageInput, context: AiContext): AiProposal;
  proposeFromCsv(input: AiCsvInput, context: AiContext): AiProposal;
}

AiContext {
  scope: "selected_accounts" | "full_ledger";
  accounts: Account[];
  holdings: Holding[];
  recentMovements: Movement[];
  categories: Category[];
  counterparties: Counterparty[];
}
```

规则：

- Provider 只返回 proposal。
- Provider 不获得写账 port。
- Provider 不获得交易/转账能力。
- full ledger context 只用于生成候选。

### SyncClientPort

```ts
SyncClientPort {
  bootstrap(): SyncBootstrapResult;
  pullChanges(cursor?: string): SyncPullResponse;
  pushChanges(changes: SyncChange[]): SyncPushResult;
}
```

规则：

- debug fixture 模式下该 port 必须禁用。
- 冲突必须返回给应用层，不静默合并金额/账户/币种冲突。

## 5. Utility ports

```ts
ClockPort {
  now(): ISODateTime;
  today(): ISODate;
}

IdGeneratorPort {
  newId(): ID;
}

DecimalPort {
  add(a: DecimalString, b: DecimalString): DecimalString;
  subtract(a: DecimalString, b: DecimalString): DecimalString;
  multiply(a: DecimalString, b: DecimalString): DecimalString;
  divide(a: DecimalString, b: DecimalString): DecimalString;
  isValid(value: DecimalString): boolean;
}
```

规则：

- 金额/价格/数量不使用浮点数计算。
- 测试时 Clock / IdGenerator 必须可替换。

## 6. Use case invariants

### Confirm atomic group

```ts
confirmAtomicGroup(groupId: ID): ConfirmResult
```

流程：

1. 读取 atomic group。
2. 校验状态为 pending / edited。
3. 重新运行 validation。
4. 事务写入 confirmed movements/entities。
5. 更新 proposal group 状态。
6. 标记快照过期。
7. 追加 sync outbox。

失败条件：

- validation 失败。
- group 不存在。
- group 已审批/拒绝。
- confirmed movement 将被静默覆盖。

### Create correction

```ts
createCorrection(input: CreateCorrectionInput): AiAtomicGroup
```

规则：

- 对 confirmed movement 的修改默认产生 correction proposal。
- correction proposal 必须包含 old → new diff。
- 用户确认后写入新 Movement，不覆盖原 Movement。

### Mark DCA executed

```ts
markDcaExecutedAsProposal(reminderId: ID): AiAtomicGroup
```

规则：

- 只生成 proposal。
- 不下单。
- 不转账。
- 不连接券商交易接口。

## 7. Data source mode

```ts
DataSourceMode = "real_local" | "debug_fixture" | "api_remote";
```

规则：

- `real_local` 是默认。
- `debug_fixture` 使用独立 store，实现同样 ports，但永不进入 sync outbox。
- `api_remote` 走 HTTP API，但仍不得暴露交易权限。

## 8. 后续实现建议

优先顺序：

1. 先实现 contract check。
2. 再实现纯内存 LedgerCore，用于单元测试领域规则。
3. 再决定 Rust + SQLite + 加密 或 Dart 本地实现。
4. 最后接 VPS sync。

不建议一开始直接写数据库表。先把 atomic group、proposal 隔离、snapshot invalidation、debug fixture 隔离跑通。

