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
  ├─ SubscriptionStorePort
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
  subscriptions: SubscriptionUseCases;
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

### SubscriptionUseCases

```ts
SubscriptionUseCases {
  listSubscriptions(): Subscription[];
  listUpcoming(days?: number): Subscription[];
  getSubscription(subscriptionId: ID): Subscription | null;
  createSubscription(input: CreateSubscriptionInput): Subscription;
  updateSubscription(subscriptionId: ID, patch: UpdateSubscriptionPatch): Subscription;
  cancelSubscription(subscriptionId: ID): Subscription;
  createChargeProposal(subscriptionId: ID): AiAtomicGroup;
  scanDueChargeProposals(input: SubscriptionDueScanInput): SubscriptionDueScanResult;
}
```

规则：

- 创建、编辑、暂停或取消计划只改变订阅资源，不直接写 confirmed movement。
- `createChargeProposal` 只创建待确认候选，并记录该订阅当前计费日期的 pending 引用。
- `scanDueChargeProposals` 按 `(nextChargeDate,id)` 稳定扫描到期计划；limit 只限制创建数量，逐项付款阻塞以结构化 skip 返回。
- 候选确认与拒绝复用 atomic-group 事务边界，不另建绕过复核的扣款路径。

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

### SubscriptionStorePort

```ts
SubscriptionStorePort {
  listSubscriptions(): Subscription[];
  getSubscription(id: ID): Subscription | null;
  saveSubscription(subscription: Subscription): void;
}
```

不变量：

- subscription 保存未来周期计划与 pending/last charge 引用，不等同于 confirmed movement。
- 同一订阅、同一计费日期最多有一个待确认扣费候选。
- 创建候选时，pending movement/entries 写入与订阅 pending 引用必须处于同一事务边界；无需在 proposal store 再保存副本。
- pending 指针必须引用状态为 `pending_review`、subscription ID 和计费日期均匹配的 movement；反向孤儿引用必须拒绝。
- 确认扣费时，movement 写入、pending 清除、last charge 更新和 `nextChargeDate` 推进必须处于同一事务边界。
- 拒绝候选把 movement 标记为 `cancelled` 并清除 pending 引用，不推进计费日期；历史候选保留用于追溯。

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
- `listPending` / `getProposal` 可以把 standalone pending movement group 动态投影为只读 proposal；该投影不经 `saveProposal` 持久化，避免同一 movement 双份真相。

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
5. 若为订阅扣费候选，清除 pending 引用、记录本次扣费并推进下次计费日期。
6. 更新 proposal group 状态。

投资买卖确认时：

- 买入 principal、fee、tax 的现金流出合计计入持仓成本基础。
- 卖出现金净流入等于 gross proceeds 减 fee/tax，成本基础按出售数量比例减少。
- fee/tax 必须与 principal 使用同一现金账户和币种；未提供 FX 明细时不得跨币种归集。
- 卖出确认必须把毛回款、费用合计、净回款、平均成本释放额及已实现盈亏计算状态固化到
  confirmed movement；不允许前端提交或覆盖派生结果。
- 成交换算只能选择 `FXRate.asOf <= Movement.occurredAt` 的最近一条，反向货币对使用倒数；
  实际 rate、来源 ID、来源时间和是否倒数必须随 movement 固化。
7. 标记快照过期。
8. 追加 sync outbox。

返回值必须包含 `ledgerWrite`；调用方只能在 `ledgerWrite=true` 时展示“已入账”或按正式账本写入刷新派生视图。

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
markDcaExecutedAsProposal(reminderId: ID, input: DcaExecutionInput): AiAtomicGroup
```

规则：

- 只生成 proposal。
- `input.quantity` 形成持仓腿，`input.totalCost` 形成现金腿；计划金额不能代替成交数量。
- 资金账户必须支持成本币种；持仓账户必须支持持仓并支持标的报价币种。
- 同一 reminder 只能有一个 pending proposal；同一幂等请求可安全重放。
- 不下单。
- 不转账。
- 不连接券商交易接口。
- pending proposal / draft 可以持久化，但用户确认前不得写入 confirmed/effective ledger。
- 确认 atomic group 后才影响余额、持仓、净值和快照。

### Generate subscription charge proposal

```ts
createSubscriptionChargeProposal(subscriptionId: ID): AiAtomicGroup
```

规则：

- 只为 active / trial 且存在下一计费日期的计划生成支出候选。
- 金额保持订阅原币种，付款账户必须支持该币种。
- 已存在 pending 扣费候选时返回冲突，不重复创建。
- 确认前不影响余额、流水、净值或快照；确认后才推进计划日期。
- 不调用支付平台，不执行自动续费或真实代扣。

### Scan due subscription charge proposals

```ts
scanDueChargeProposals(input: SubscriptionDueScanInput): SubscriptionDueScanResult
```

规则：

- `throughDate` 是必填本地 ISO 日历日；limit 默认 100，范围 1–200，未知字段必须拒绝。
- 只扫描 `trial|active` 且 `nextChargeDate <= throughDate` 的计划，按 `(nextChargeDate,id)` 稳定排序。
- 已 pending、付款账户不可用、付款币种不受支持分别返回 `already_pending`、`payment_account_unavailable`、`payment_currency_unsupported`；单项 skip 不终止批次。
- 账户或支持币种在计划创建后发生漂移时，不自动换汇或修改计划；单条和批量生成都必须重新校验付款能力。
- limit 只约束新建候选数；`remainingEligibleCount` 只统计因 limit 未创建的可创建项目，`hasMore` 与其是否大于零一致。
- 扫描与所有候选写入必须共用一次事务和一次幂等结果提交；任一非预期不变量错误整批回滚。
- 只创建待复核 movement，不确认、不扣款、不推进日期，也不启动后台 timer。

## 7. Data source mode

```ts
DataSourceMode = "real_local" | "debug_fixture" | "local_server" | "api_remote";
```

规则：

- `real_local` 是 Flutter 默认空壳 adapter，当前不直接打开 JSON 文件。
- `debug_fixture` 使用独立 store，实现同样 ports，但永不进入 sync outbox。
- `local_server` 通过 localhost HTTP 调 Rust；只有服务挂载 `--ledger-path` 时才是当前真实本地持久化实现。
- `api_remote` 走 HTTP API，但仍不得暴露交易权限。

## 8. 后续实现建议

优先顺序：

1. 先实现 contract check。
2. 再实现纯内存 LedgerCore，用于单元测试领域规则。
3. 再决定 Rust + SQLite + 加密 或 Dart 本地实现。
4. 最后接 VPS sync。

不建议一开始直接写数据库表。先把 atomic group、proposal 隔离、snapshot invalidation、debug fixture 隔离跑通。
