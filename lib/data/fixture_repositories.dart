// Wealth Ledger — debug_fixture 仓库：隔离的 DEMO 数据（对齐 examples/portfolio_overview_degraded）。
// 仅 debug/demo 模式注入；绝不写真实账本、绝不参与同步。所有数据均为虚构演示。
import '../core/types.dart';
import 'repositories.dart';
import 'view_models.dart';

const String _asOf = '2026-06-25T09:30:00+08:00';
const String _asOfPrev = '2026-06-24T09:30:00+08:00';

const List<AccountVm> _accounts = [
  AccountVm(
    id: 'acct_cmb_cny',
    displayName: '招行储蓄卡',
    accountType: AccountType.bank,
    isLiability: false,
    value: ValuedMoney(
      amount: '38240.33',
      currency: 'CNY',
      asOf: _asOf,
      quality: ValueQuality.exact,
    ),
  ),
  AccountVm(
    id: 'acct_us_broker',
    displayName: '美股券商',
    accountType: AccountType.brokerage,
    isLiability: false,
    value: ValuedMoney(
      amount: '110320.00',
      currency: 'CNY',
      asOf: _asOf,
      quality: ValueQuality.estimated,
    ),
  ),
  AccountVm(
    id: 'acct_crypto',
    displayName: '数字资产',
    accountType: AccountType.exchange,
    isLiability: false,
    value: ValuedMoney(
      amount: '31870.00',
      currency: 'CNY',
      asOf: _asOf,
      quality: ValueQuality.estimated,
    ),
  ),
  AccountVm(
    id: 'acct_psbc_loan',
    displayName: '邮储助学贷款',
    accountType: AccountType.loan,
    isLiability: true,
    value: ValuedMoney(
      amount: '-9620.00',
      currency: 'CNY',
      asOf: _asOf,
      quality: ValueQuality.exact,
    ),
    note: '在校贴息',
  ),
];

const List<HoldingVm> _holdings = [
  HoldingVm(
    id: 'holding_nvda',
    accountId: 'acct_us_broker',
    symbol: 'NVDA',
    displayName: 'NVIDIA',
    quantity: '12',
    quoteStatus: QuoteStatus.stale,
    costBasisTotal: Money(amount: '61800.00', currency: 'CNY'),
    marketValue: ValuedMoney(
      amount: '65000.00',
      currency: 'CNY',
      asOf: _asOf,
      quality: ValueQuality.estimated,
    ),
    dayChange: Money(amount: '520.00', currency: 'CNY'),
    unrealizedPnl: Money(amount: '3200.00', currency: 'CNY'),
    unrealizedPnlRate: '0.0518',
  ),
  HoldingVm(
    id: 'holding_aapl',
    accountId: 'acct_us_broker',
    symbol: 'AAPL',
    displayName: 'Apple',
    quantity: '20',
    quoteStatus: QuoteStatus.stale,
    costBasisTotal: Money(amount: '40640.00', currency: 'CNY'),
    marketValue: ValuedMoney(
      amount: '40000.00',
      currency: 'CNY',
      asOf: _asOf,
      quality: ValueQuality.estimated,
    ),
    dayChange: Money(amount: '-120.00', currency: 'CNY'),
    unrealizedPnl: Money(amount: '-640.00', currency: 'CNY'),
    unrealizedPnlRate: '-0.0157',
  ),
  HoldingVm(
    id: 'holding_btc',
    accountId: 'acct_crypto',
    symbol: 'BTC',
    displayName: 'Bitcoin',
    quantity: '0.0300',
    quoteStatus: QuoteStatus.fresh,
    costBasisTotal: Money(amount: '17770.00', currency: 'CNY'),
    marketValue: ValuedMoney(
      amount: '18870.00',
      currency: 'CNY',
      asOf: _asOf,
      quality: ValueQuality.estimated,
    ),
    unrealizedPnl: Money(amount: '1100.00', currency: 'CNY'),
    unrealizedPnlRate: '0.0619',
  ),
];

const List<MovementVm> _movements = [
  MovementVm(
    id: 'mov_transfer_pending_001',
    atomicGroupId: 'ag_transfer_pending_001',
    type: MovementType.transfer,
    status: MovementStatus.inTransit,
    title: '招行 → 美股券商',
    occurredAt: _asOf,
    displayAmount: Money(amount: '500.00', currency: 'CNY'),
    inTransit: true,
  ),
  MovementVm(
    id: 'mov_salary_001',
    atomicGroupId: 'ag_salary_001',
    type: MovementType.income,
    status: MovementStatus.confirmed,
    title: '工资入账',
    occurredAt: _asOf,
    displayAmount: Money(amount: '12000.00', currency: 'CNY'),
  ),
  MovementVm(
    id: 'mov_takeout_001',
    atomicGroupId: 'ag_takeout_001',
    type: MovementType.expense,
    status: MovementStatus.confirmed,
    title: '外卖平台',
    occurredAt: _asOf,
    displayAmount: Money(amount: '20.00', currency: 'CNY'),
    amountBreakdown: TransactionAmountBreakdownVm(
      gross: Money(amount: '30.00', currency: 'CNY'),
      savings: Money(amount: '10.00', currency: 'CNY'),
      paid: Money(amount: '20.00', currency: 'CNY'),
    ),
  ),
];

const List<CategoryVm> _categories = [
  CategoryVm(
    id: 'cat_salary',
    displayName: '工资收入',
    kind: CategoryKind.income,
    aiDescription: '工资、劳务收入、平台结算收入',
  ),
  CategoryVm(
    id: 'cat_coffee',
    displayName: '咖啡饮品',
    kind: CategoryKind.expense,
    aiDescription: '咖啡、奶茶、饮品消费',
  ),
  CategoryVm(
    id: 'cat_investment_dca',
    displayName: '定投投入',
    kind: CategoryKind.investment,
    aiDescription: '定投、买入基金或股票的资金投入记录',
  ),
];

const List<CounterpartyVm> _counterparties = [
  CounterpartyVm(
    id: 'cp_luckin',
    displayName: '瑞幸咖啡',
    aliases: ['瑞幸', 'Luckin Coffee'],
    normalizedName: '瑞幸咖啡',
    categoryHintId: 'cat_coffee',
  ),
  CounterpartyVm(
    id: 'cp_salary',
    displayName: '工资发放方',
    aliases: ['公司', '雇主'],
    normalizedName: '工资发放方',
    categoryHintId: 'cat_salary',
  ),
];

const List<DcaReminderVm> _dcaReminders = [
  DcaReminderVm(
    id: 'rem_csi300_0710',
    planId: 'plan_csi300',
    displayName: '沪深300ETF',
    plannedAmount: Money(amount: '1000.00', currency: 'CNY'),
    dueDate: '2026-07-10',
    status: DcaReminderStatus.due,
  ),
];

const List<DcaPlanVm> _dcaPlans = [
  DcaPlanVm(
    id: 'plan_csi300',
    displayName: '沪深300ETF',
    plannedAmount: Money(amount: '1000.00', currency: 'CNY'),
    frequency: DcaFrequency.monthly,
    nextDueDate: '2026-07-10',
    status: DcaPlanStatus.active,
  ),
  DcaPlanVm(
    id: 'plan_nasdaq',
    displayName: '纳指ETF',
    plannedAmount: Money(amount: '800.00', currency: 'CNY'),
    frequency: DcaFrequency.monthly,
    nextDueDate: '2026-07-25',
    status: DcaPlanStatus.active,
  ),
];

const List<AiProposalVm> _proposals = [
  AiProposalVm(
    id: 'prop_modify_001',
    status: AiProposalStatus.pending,
    sourceLabel: '截图 IMG_0142.png',
    summary: 'AI 修改 1 笔交易',
    groups: [
      AiAtomicGroupVm(
        id: 'ag_modify_t1',
        title: '修改：瑞幸咖啡',
        operation: AiOperation.modify,
        status: AiGroupStatus.pending,
        diffs: [
          AiFieldDiffVm(
            fieldPath: '金额',
            oldValue: '¥18.00',
            newValue: '¥21.00',
            changed: true,
            severity: AiDiffSeverity.important,
          ),
          AiFieldDiffVm(
            fieldPath: '对方',
            oldValue: '瑞幸',
            newValue: '瑞幸咖啡(臻选店)',
            changed: true,
          ),
          AiFieldDiffVm(
            fieldPath: '分类',
            oldValue: '餐饮/咖啡',
            newValue: '餐饮/咖啡',
            changed: false,
          ),
        ],
      ),
    ],
  ),
  AiProposalVm(
    id: 'prop_create_001',
    status: AiProposalStatus.pending,
    sourceLabel: '文本输入',
    summary: 'AI 新增 1 笔消费',
    groups: [
      AiAtomicGroupVm(
        id: 'ag_create_coffee',
        title: '新增：瑞幸咖啡 ¥18.00',
        operation: AiOperation.create,
        status: AiGroupStatus.pending,
      ),
    ],
  ),
];

const List<AccountAnomalyVm> _anomalies = [
  AccountAnomalyVm(
    id: 'anom_broker_stale',
    accountName: '美股券商',
    kind: AnomalyKind.quoteStale,
    severity: AnomalySeverity.warning,
    detail: 'AAPL / NVDA 报价已过期，使用本地缓存',
  ),
];

const NetWorthSnapshotVm _latest = NetWorthSnapshotVm(
  id: 'snap_latest',
  snapshotAt: _asOf,
  grossAssets: Money(amount: '255298.90', currency: 'CNY'),
  totalLiabilities: Money(amount: '9620.00', currency: 'CNY'),
  netWorth: Money(amount: '245678.90', currency: 'CNY'),
  quality: ValueQuality.estimated,
);

const NetWorthSnapshotVm _previous = NetWorthSnapshotVm(
  id: 'snap_prev',
  snapshotAt: _asOfPrev,
  grossAssets: Money(amount: '253900.00', currency: 'CNY'),
  totalLiabilities: Money(amount: '9466.77', currency: 'CNY'),
  netWorth: Money(amount: '244433.23', currency: 'CNY'),
  quality: ValueQuality.estimated,
);

const PortfolioOverviewVm _overview = PortfolioOverviewVm(
  latestSnapshot: _latest,
  previousSnapshot: _previous,
  pendingSummary: PendingSummaryVm(
    aiPendingCount: 2,
    accountAnomalyCount: 1,
    dcaDueCount: 1,
    inTransitCount: 1,
    quoteProblemCount: 2,
  ),
  quoteStatusSummary: QuoteStatusSummaryVm(freshCount: 8, staleCount: 2),
  primaryHoldings: _holdings,
  recentMovements: _movements,
  changeSinceLastSnapshot: Money(amount: '1245.67', currency: 'CNY'),
);

const AssetAllocationVm _allocation = AssetAllocationVm(
  slices: [
    AllocationSliceVm(
      category: '现金与活期',
      percent: '30.5',
      value: Money(amount: '77900.45', currency: 'CNY'),
    ),
    AllocationSliceVm(
      category: '美股',
      percent: '43.2',
      value: Money(amount: '110320.00', currency: 'CNY'),
    ),
    AllocationSliceVm(
      category: '数字资产',
      percent: '12.5',
      value: Money(amount: '31870.00', currency: 'CNY'),
    ),
    AllocationSliceVm(
      category: '其他资产',
      percent: '13.8',
      value: Money(amount: '35208.45', currency: 'CNY'),
    ),
  ],
  totalAssets: Money(amount: '255298.90', currency: 'CNY'),
  totalLiabilities: Money(amount: '9620.00', currency: 'CNY'),
  netWorth: Money(amount: '245678.90', currency: 'CNY'),
);

class FixtureAccountRepository implements AccountRepository {
  const FixtureAccountRepository();
  @override
  Future<List<AccountVm>> listAccounts() async => _accounts;
  @override
  Future<AccountVm?> getAccount(Id id) async => _accounts
      .where((a) => a.id == id)
      .cast<AccountVm?>()
      .firstWhere((a) => true, orElse: () => null);
  @override
  Future<List<AccountAnomalyVm>> listAnomalies() async => _anomalies;
  @override
  Future<AccountVm> createAccount(CreateAccountInput input) async =>
      throw UnsupportedError('DEMO 演示只读，不支持账户写入；请用 local_server');
  @override
  Future<AccountVm> updateAccount(Id id, CreateAccountInput input) async =>
      throw UnsupportedError('DEMO 演示只读，不支持账户写入；请用 local_server');
  @override
  Future<void> archiveAccount(Id id) async =>
      throw UnsupportedError('DEMO 演示只读，不支持账户写入；请用 local_server');
}

class FixturePortfolioRepository implements PortfolioRepository {
  const FixturePortfolioRepository();
  @override
  Future<PortfolioOverviewVm> getOverview() async => _overview;
  @override
  Future<List<HoldingVm>> listHoldings() async => _holdings;
  @override
  Future<List<HoldingVm>> listHoldingsByAccount(Id accountId) async =>
      _holdings.where((h) => h.accountId == accountId).toList();
  @override
  Future<AssetAllocationVm> getAssetAllocation() async => _allocation;
}

class FixtureMovementRepository implements MovementRepository {
  const FixtureMovementRepository();
  @override
  Future<List<MovementVm>> listRecentMovements({int limit = 20}) async =>
      _movements.take(limit).toList();
  @override
  Future<MovementVm?> getMovement(Id id) async => _movements
      .where((m) => m.id == id)
      .cast<MovementVm?>()
      .firstWhere((m) => true, orElse: () => null);
  @override
  Future<MovementVm> createManualRecord(ManualRecordInput input) async =>
      throw UnsupportedError('DEMO 演示只读，不支持手动记账；请用 local_server');
  @override
  Future<MovementVm> createTransfer(TransferInput input) async =>
      throw UnsupportedError('DEMO 演示只读，不支持转账；请用 local_server');
  @override
  Future<MovementVm> reconcileBalance(ReconcileInput input) async =>
      throw UnsupportedError('DEMO 演示只读，不支持余额校准；请用 local_server');
  @override
  Future<void> createCorrectionProposal(CreateCorrectionInput input) async {
    /* DEMO：模拟生成更正候选，演示数据不变 */
  }
}

class FixtureTaxonomyRepository implements TaxonomyRepository {
  const FixtureTaxonomyRepository();
  @override
  Future<List<CategoryVm>> listCategories() async => _categories;
  @override
  Future<CategoryVm> createCategory(CreateCategoryInput input) async =>
      throw UnsupportedError('DEMO 演示只读，不支持创建分类；请用 local_server');
  @override
  Future<CategoryVm> updateCategory(Id id, CreateCategoryInput input) async =>
      throw UnsupportedError('DEMO 演示只读，不支持编辑分类；请用 local_server');
  @override
  Future<List<CounterpartyVm>> listCounterparties() async => _counterparties;
  @override
  Future<CounterpartyVm> createCounterparty(
    CreateCounterpartyInput input,
  ) async => throw UnsupportedError('DEMO 演示只读，不支持创建对手方；请用 local_server');
  @override
  Future<CounterpartyVm> updateCounterparty(
    Id id,
    CreateCounterpartyInput input,
  ) async => throw UnsupportedError('DEMO 演示只读，不支持编辑对手方；请用 local_server');
  @override
  Future<void> createCounterpartyMergeProposal({
    required List<Id> sourceCounterpartyIds,
    required String targetDisplayName,
  }) async {
    /* DEMO：模拟生成合并候选，演示数据不变 */
  }
}

class FixtureDcaRepository implements DcaRepository {
  const FixtureDcaRepository();
  @override
  Future<List<DcaReminderVm>> listDueReminders() async => _dcaReminders;
  @override
  Future<List<DcaPlanVm>> listPlans() async => _dcaPlans;
  @override
  Future<DcaPlanVm> createPlan(CreateDcaPlanInput input) async =>
      throw UnsupportedError('DEMO 演示只读，不支持创建定投计划；请用 local_server');
  @override
  Future<void> markExecutedAsProposal(Id reminderId) async {
    /* DEMO：模拟生成候选 */
  }
  @override
  Future<void> skipReminder(Id reminderId) async {
    /* DEMO：模拟跳过 */
  }

  @override
  Future<void> snoozeReminder(Id reminderId, {required IsoDate until}) async {
    /* DEMO：模拟暂缓 */
  }
}

class FixtureQuoteRepository implements QuoteRepository {
  const FixtureQuoteRepository();
  @override
  Future<QuoteStatusSummaryVm> getQuoteSummary() async =>
      const QuoteStatusSummaryVm(freshCount: 8, staleCount: 2);
  @override
  Future<QuoteRefreshResultVm> refreshQuotes({required String mode}) async =>
      const QuoteRefreshResultVm(
        status: 'partial_success',
        completedAt: _asOf,
        quoteCount: 2,
        fxRateCount: 1,
        errors: ['刷新失败，继续使用缓存报价。'],
      );
}

class FixtureAiProposalRepository implements AiProposalRepository {
  const FixtureAiProposalRepository();
  @override
  Future<List<AiProposalVm>> listPending() async => _proposals;
  @override
  Future<AiProposalVm?> getProposal(Id id) async => _proposals
      .where((p) => p.id == id)
      .cast<AiProposalVm?>()
      .firstWhere((p) => true, orElse: () => null);
  @override
  Future<void> approveAtomicGroup(Id groupId) async {
    /* DEMO：模拟接受，演示数据不变 */
  }
  @override
  Future<void> rejectAtomicGroup(Id groupId, {String? reason}) async {
    /* DEMO：模拟拒绝 */
  }
  @override
  Future<void> createFromText(String text) async {
    /* DEMO：模拟生成候选（演示数据不变）*/
  }
  @override
  Future<void> createFromCsv(
    String csv, {
    Id? defaultAccountId,
    String? defaultCurrency,
  }) async {
    /* DEMO：模拟 CSV 候选（演示数据不变）*/
  }

  @override
  Future<void> createFromImage({
    required String fileName,
    required String imageBase64,
    String? mimeType,
  }) async {
    /* DEMO：模拟图片候选（演示数据不变）*/
  }

  @override
  Future<void> editAtomicGroup(Id groupId, ManualRecordInput input) async {
    /* DEMO：模拟编辑 */
  }
}

class FixtureSnapshotRepository implements SnapshotRepository {
  const FixtureSnapshotRepository();
  @override
  Future<NetWorthSnapshotVm?> getLatest() async => _latest;
  @override
  Future<List<NetWorthSnapshotVm>> listSnapshots() async => const [
    _latest,
    _previous,
  ];
  @override
  Future<NetWorthSnapshotVm> createManualSnapshot({
    required String reason,
  }) async => throw UnsupportedError('DEMO 演示只读，不支持创建快照；请用 local_server');
}
