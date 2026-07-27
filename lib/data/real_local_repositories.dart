// Wealth Ledger — real_local 仓库：默认空账本。
// 不加载 fixture、不写真实账本、不报错、不接真实行情/AI/同步。
// TODO(LOCAL_LEDGER_FORMAT_V1): 接真实本地账本（由后端线 / Rust core 提供）；当前一律返回空。
import '../core/types.dart';
import 'repositories.dart';
import 'view_models.dart';

class RealLocalLedgerRepository implements LedgerRepository {
  const RealLocalLedgerRepository();

  /// real_local 目前是只读空壳：能力全 false，写入口由 UI 隐藏/禁用。
  @override
  Future<LedgerCapabilitiesVm> getCapabilities() async =>
      const LedgerCapabilitiesVm(
        dataSourceMode: 'real_local',
        canWriteConfirmedLedger: false,
        canCreateAccount: false,
        canRecordMovement: false,
        canConfirmProposal: false,
        canPersistPendingProposal: false,
        proposalPersistence: 'none',
      );
}

class RealLocalAccountRepository implements AccountRepository {
  const RealLocalAccountRepository();
  @override
  Future<List<AccountVm>> listAccounts() async => const [];
  @override
  Future<AccountVm?> getAccount(Id id) async => null;
  @override
  Future<List<AccountAnomalyVm>> listAnomalies() async => const [];
  @override
  Future<AccountVm> createAccount(CreateAccountInput input) async =>
      throw UnsupportedError('real_local 暂不支持建账户；请用 local_server');
  @override
  Future<AccountVm> updateAccount(Id id, CreateAccountInput input) async =>
      throw UnsupportedError('real_local 暂不支持改账户；请用 local_server');
  @override
  Future<void> archiveAccount(Id id) async =>
      throw UnsupportedError('real_local 暂不支持归档；请用 local_server');
}

class RealLocalTaxonomyRepository implements TaxonomyRepository {
  const RealLocalTaxonomyRepository();
  @override
  Future<List<CategoryVm>> listCategories() async => const [];
  @override
  Future<CategoryVm> createCategory(CreateCategoryInput input) async =>
      throw UnsupportedError('real_local 暂不支持创建分类；请用 local_server');
  @override
  Future<CategoryVm> updateCategory(Id id, CreateCategoryInput input) async =>
      throw UnsupportedError('real_local 暂不支持编辑分类；请用 local_server');
  @override
  Future<List<CounterpartyVm>> listCounterparties() async => const [];
  @override
  Future<CounterpartyVm> createCounterparty(
    CreateCounterpartyInput input,
  ) async => throw UnsupportedError('real_local 暂不支持创建对手方；请用 local_server');
  @override
  Future<CounterpartyVm> updateCounterparty(
    Id id,
    CreateCounterpartyInput input,
  ) async => throw UnsupportedError('real_local 暂不支持编辑对手方；请用 local_server');
  @override
  Future<void> createCounterpartyMergeProposal({
    required List<Id> sourceCounterpartyIds,
    required String targetDisplayName,
  }) async => throw UnsupportedError('real_local 暂不支持对手方合并；请用 local_server');
}

class RealLocalPortfolioRepository implements PortfolioRepository {
  const RealLocalPortfolioRepository();
  @override
  Future<PortfolioOverviewVm> getOverview() async => const PortfolioOverviewVm(
    pendingSummary: PendingSummaryVm(),
    quoteStatusSummary: QuoteStatusSummaryVm(),
    primaryHoldings: [],
    recentMovements: [],
  );
  @override
  Future<List<HoldingVm>> listHoldings() async => const [];
  @override
  Future<List<HoldingVm>> listHoldingsByAccount(Id accountId) async => const [];
  @override
  Future<AssetAllocationVm> getAssetAllocation() async =>
      const AssetAllocationVm(
        slices: [],
        totalAssets: Money(amount: '0', currency: 'CNY'),
        totalLiabilities: Money(amount: '0', currency: 'CNY'),
        netWorth: Money(amount: '0', currency: 'CNY'),
      );
  @override
  Future<AiAtomicGroupVm> proposeHoldingAdjustment(
    Id accountId,
    HoldingAdjustmentInput input,
  ) async => throw UnsupportedError('real_local 暂不支持持仓校准；请用 local_server');

  /// 不伪造"没有问题"：该数据源没有估值读模型，直接报不支持。
  @override
  Future<List<ValuationIssueVm>> listValuationIssues() async =>
      throw UnsupportedError('real_local 暂不支持估值状态；请用 local_server');
}

class RealLocalMovementRepository implements MovementRepository {
  const RealLocalMovementRepository();
  @override
  Future<List<MovementVm>> listRecentMovements({int limit = 20}) async =>
      const [];
  @override
  Future<MovementVm?> getMovement(Id id) async => null;
  @override
  Future<ConfirmResultVm> createManualRecord(ManualRecordInput input) async =>
      throw UnsupportedError('real_local 暂不支持手动记账；请用 local_server');
  @override
  Future<ConfirmResultVm> createTransfer(TransferInput input) async =>
      throw UnsupportedError('real_local 暂不支持转账；请用 local_server');
  @override
  Future<ConfirmResultVm> reconcileBalance(ReconcileInput input) async =>
      throw UnsupportedError('real_local 暂不支持余额校准；请用 local_server');
  @override
  Future<void> createCorrectionProposal(CreateCorrectionInput input) async =>
      throw UnsupportedError('real_local 暂不支持发起更正；请用 local_server');

  @override
  Future<ConfirmResultVm> createInvestmentTrade(
    InvestmentTradeInput input,
  ) async => throw UnsupportedError('real_local 暂不支持记录投资成交；请用 local_server');
}

class RealLocalInstrumentRepository implements InstrumentRepository {
  const RealLocalInstrumentRepository();
  @override
  Future<List<InstrumentVm>> listInstruments() async => const [];
  @override
  Future<InstrumentVm> createInstrument(CreateInstrumentInput input) async =>
      throw UnsupportedError('real_local 暂不支持创建标的；请用 local_server');
}

class RealLocalDcaRepository implements DcaRepository {
  const RealLocalDcaRepository();
  @override
  Future<List<DcaReminderVm>> listDueReminders() async => const [];
  @override
  Future<List<DcaPlanVm>> listPlans() async => const [];
  @override
  Future<DcaPlanVm> createPlan(CreateDcaPlanInput input) async =>
      throw UnsupportedError('real_local 暂不支持创建定投计划；请用 local_server');
  @override
  Future<DcaPlanVm> updatePlan(Id planId, UpdateDcaPlanPatch patch) async =>
      throw UnsupportedError('real_local 暂不支持更新定投计划；请用 local_server');
  @override
  Future<void> markExecutedAsProposal(
    Id reminderId,
    DcaExecutionInput input,
  ) async => throw UnsupportedError('real_local 暂不支持写入；请用 local_server 联调');
  @override
  Future<void> skipReminder(Id reminderId) async =>
      throw UnsupportedError('real_local 暂不支持跳过定投提醒；请用 local_server');
  @override
  Future<void> snoozeReminder(Id reminderId, {required IsoDate until}) async =>
      throw UnsupportedError('real_local 暂不支持暂缓定投提醒；请用 local_server');
}

class RealLocalLoanRepository implements LoanRepository {
  const RealLocalLoanRepository();
  @override
  Future<List<LiabilityPositionVm>> listLiabilityPositions({
    IsoDate? throughDate,
  }) async => const [];
  @override
  Future<LoanRepaymentScheduleVm> getRepaymentSchedule(
    Id accountId, {
    int limit = 24,
  }) async => throw UnsupportedError('real_local 暂不支持还款计划；请用 local_server');
  @override
  Future<AccountVm> updateLiabilityTerms(
    Id accountId,
    LiabilityTermsInput input,
  ) async => throw UnsupportedError('real_local 暂不支持贷款条款；请用 local_server');
  @override
  Future<AiAtomicGroupVm> proposeLoanInterest(
    Id accountId, {
    required IsoDate throughDate,
    String? note,
  }) async => throw UnsupportedError('real_local 暂不支持记录利息；请用 local_server');
}

class RealLocalQuoteRepository implements QuoteRepository {
  const RealLocalQuoteRepository();
  @override
  Future<QuoteStatusSummaryVm> getQuoteSummary() async =>
      const QuoteStatusSummaryVm();
  @override
  @override
  Future<QuoteRefreshResultVm> refreshQuotes({required String mode}) async =>
      QuoteRefreshResultVm(
        status: 'offline',
        completedAt: DateTime.now().toUtc().toIso8601String(),
        errors: const ['real_local 暂无行情接口；请用 local_server 联调'],
      );
}

class RealLocalAiProposalRepository implements AiProposalRepository {
  const RealLocalAiProposalRepository();
  @override
  Future<List<AiProposalVm>> listPending() async => const [];
  @override
  Future<AiProposalVm?> getProposal(Id id) async => null;
  @override
  Future<ConfirmResultVm> approveAtomicGroup(Id groupId) async =>
      throw UnsupportedError('real_local 暂不支持写入；请用 local_server 联调');
  @override
  Future<void> rejectAtomicGroup(Id groupId, {String? reason}) async =>
      throw UnsupportedError('real_local 暂不支持写入；请用 local_server 联调');
  @override
  Future<void> createFromText(String text) async =>
      throw UnsupportedError('real_local 暂不支持 AI 导入；请用 local_server 联调');
  @override
  Future<void> createFromCsv(
    String csv, {
    Id? defaultAccountId,
    String? defaultCurrency,
  }) async =>
      throw UnsupportedError('real_local 暂不支持 CSV 导入；请用 local_server 联调');

  @override
  Future<void> createFromImage({
    required String fileName,
    required String imageBase64,
    String? mimeType,
  }) async => throw UnsupportedError('real_local 暂不支持图片导入；请用 local_server 联调');

  @override
  Future<void> editAtomicGroup(Id groupId, ManualRecordInput input) async =>
      throw UnsupportedError('real_local 暂不支持 AI 编辑；请用 local_server 联调');
}

class RealLocalSnapshotRepository implements SnapshotRepository {
  const RealLocalSnapshotRepository();
  @override
  Future<NetWorthSnapshotVm?> getLatest() async => null;
  @override
  Future<List<NetWorthSnapshotVm>> listSnapshots() async => const [];
  @override
  Future<NetWorthSnapshotVm> createManualSnapshot({
    required String reason,
  }) async => throw UnsupportedError('real_local 暂不支持创建快照；请用 local_server');
}

class RealLocalSubscriptionRepository implements SubscriptionRepository {
  const RealLocalSubscriptionRepository();
  @override
  Future<List<SubscriptionVm>> listSubscriptions() async => const [];
  @override
  Future<List<SubscriptionVm>> listUpcomingSubscriptions({
    int days = 30,
  }) async => const [];
  @override
  Future<SubscriptionVm> getSubscription(Id id) async =>
      throw UnsupportedError('real_local 暂不支持订阅；请用 local_server');
  @override
  Future<SubscriptionVm> createSubscription(
    CreateSubscriptionInput input,
  ) async => throw UnsupportedError('real_local 暂不支持创建订阅；请用 local_server');
  @override
  Future<SubscriptionVm> updateSubscription(
    Id id,
    UpdateSubscriptionInput input,
  ) async => throw UnsupportedError('real_local 暂不支持编辑订阅；请用 local_server');
  @override
  Future<SubscriptionVm> cancelSubscription(Id id) async =>
      throw UnsupportedError('real_local 暂不支持取消订阅；请用 local_server');
  @override
  Future<AiAtomicGroupVm> createChargeProposal(Id id) async =>
      throw UnsupportedError('real_local 暂不支持生成扣费候选；请用 local_server');
  @override
  Future<SubscriptionDueScanResultVm> scanDueChargeProposals({
    required IsoDate throughDate,
    int limit = 100,
  }) async => throw UnsupportedError('real_local 暂不支持到期扫描；请用 local_server');
}
