// Wealth Ledger — Repository 抽象接口（前端唯一数据入口）。
// 命名对齐 DATA_SCHEMA_V1 §14；方法对齐 APPLICATION_INTERFACES_V1 的读路径。
// 第一阶段只暴露读方法 + 空/隔离实现；写路径（confirmAtomicGroup / approve /
// markExecutedAsProposal 等）在后续批次补，并仍走"候选→确认"。
import 'view_models.dart';
import '../core/types.dart';

/// 账本能力：写入口 gating 的服务端口径（/v1/ledger/bootstrap.data.capabilities）。
/// UI 只凭该结果显示/禁用写入口，不按 DataSourceMode 猜测。
abstract interface class LedgerRepository {
  Future<LedgerCapabilitiesVm> getCapabilities();
}

abstract interface class AccountRepository {
  Future<List<AccountVm>> listAccounts();
  Future<AccountVm?> getAccount(Id id);
  Future<List<AccountAnomalyVm>> listAnomalies();
  // 写路径（仅 local_server 真实账本；real_local / DEMO 不支持）。
  Future<AccountVm> createAccount(CreateAccountInput input);
  Future<AccountVm> updateAccount(Id id, CreateAccountInput input);
  Future<void> archiveAccount(Id id);
}

abstract interface class TaxonomyRepository {
  Future<List<CategoryVm>> listCategories();
  Future<CategoryVm> createCategory(CreateCategoryInput input);
  Future<CategoryVm> updateCategory(Id id, CreateCategoryInput input);
  Future<List<CounterpartyVm>> listCounterparties();
  Future<CounterpartyVm> createCounterparty(CreateCounterpartyInput input);
  Future<CounterpartyVm> updateCounterparty(
    Id id,
    CreateCounterpartyInput input,
  );

  /// 对手方合并：只生成 AI/atomic group 候选；确认前不改对手方、不改历史记录。
  Future<void> createCounterpartyMergeProposal({
    required List<Id> sourceCounterpartyIds,
    required String targetDisplayName,
  });
}

abstract interface class PortfolioRepository {
  Future<PortfolioOverviewVm> getOverview();
  Future<List<HoldingVm>> listHoldings();
  Future<List<HoldingVm>> listHoldingsByAccount(Id accountId);
  Future<AssetAllocationVm> getAssetAllocation();

  /// 持仓导入/数量校准：只生成待确认调整（进 AI 审核），确认前不动持仓。
  /// 同一持仓已有待确认调整时服务端返回 409。仅 local_server。
  Future<AiAtomicGroupVm> proposeHoldingAdjustment(
    Id accountId,
    HoldingAdjustmentInput input,
  );
}

abstract interface class MovementRepository {
  Future<List<MovementVm>> listRecentMovements({int limit = 20});
  Future<MovementVm?> getMovement(Id id);

  /// 手动记账：草稿 → 提交复核 → 确认入账（候选→确认，全程用户主动发起）。
  /// 仅 local_server 真实账本；real_local / DEMO 不支持。
  /// 返回服务端确认结果；UI 以 ledgerWrite 为准判断是否已入账。
  Future<ConfirmResultVm> createManualRecord(ManualRecordInput input);

  /// 转账：账户间转移（双分录草稿 → 复核 → 确认）。仅 local_server。
  Future<ConfirmResultVm> createTransfer(TransferInput input);

  /// 余额观察/校准：对差额生成 adjustment 候选并确认入账。仅 local_server。
  Future<ConfirmResultVm> reconcileBalance(ReconcileInput input);

  /// 已确认记录更正：只生成 correction 候选；确认前不改原记录、不影响余额。
  Future<void> createCorrectionProposal(CreateCorrectionInput input);

  /// 手动投资成交（买入/卖出多腿：现金腿 + 持仓腿 + 可选费用/税费腿）。
  /// 走草稿 → 复核 → 确认流水线；仅 local_server。是否已入账以 ledgerWrite 为准。
  Future<ConfirmResultVm> createInvestmentTrade(InvestmentTradeInput input);
}

/// 投资标的：买入只能从服务端已有标的中选择（可紧凑新建），不手填 wire ID。
abstract interface class InstrumentRepository {
  Future<List<InstrumentVm>> listInstruments();
  Future<InstrumentVm> createInstrument(CreateInstrumentInput input);
}

abstract interface class DcaRepository {
  Future<List<DcaReminderVm>> listDueReminders();
  Future<List<DcaPlanVm>> listPlans();
  Future<DcaPlanVm> createPlan(CreateDcaPlanInput input);
  Future<DcaPlanVm> updatePlan(Id planId, UpdateDcaPlanPatch patch);

  /// 「记录已执行」：只生成待确认候选记录；不下单、不转账、不连券商。
  /// 「记录已执行」：提交真实成交（数量/总成本/持仓账户），只生成待确认候选。
  /// 同一 reminder 已有 pending 时服务端返回 409。
  Future<void> markExecutedAsProposal(Id reminderId, DcaExecutionInput input);
  Future<void> skipReminder(Id reminderId);
  Future<void> snoozeReminder(Id reminderId, {required IsoDate until});
}

/// 贷款：条款维护 + 应计利息候选 + 还款计划投影。
/// 应计/拆分/计划一律来自服务端；「记录利息」只生成待确认候选（进 AI 审核）。
abstract interface class LoanRepository {
  Future<List<LiabilityPositionVm>> listLiabilityPositions({
    IsoDate? throughDate,
  });
  Future<LoanRepaymentScheduleVm> getRepaymentSchedule(
    Id accountId, {
    int limit = 24,
  });
  Future<AccountVm> updateLiabilityTerms(
    Id accountId,
    LiabilityTermsInput input,
  );
  Future<AiAtomicGroupVm> proposeLoanInterest(
    Id accountId, {
    required IsoDate throughDate,
    String? note,
  });
}

/// 固定收益（存款/理财/债券类持仓）条款与计息。
/// 本金、应计利息、状态一律来自服务端；「记录利息」只生成待确认候选。
abstract interface class YieldRepository {
  Future<List<YieldPositionVm>> listYieldPositions({IsoDate? throughDate});
  Future<HoldingVm> updateYieldTerms(Id holdingId, YieldTermsInput input);
  Future<AiAtomicGroupVm> proposeInterest(
    Id holdingId, {
    required IsoDate throughDate,
    String? note,
  });
}

abstract interface class QuoteRepository {
  Future<QuoteStatusSummaryVm> getQuoteSummary();
  Future<QuoteRefreshResultVm> refreshQuotes({required String mode});

  /// 汇率列表（只读）：用于估值状态面板判断币种是否有到本位币的路径，
  /// 以及区分"较旧/缓存/缺失"；前端不用它做任何换算。
  Future<List<FxRateVm>> listFxRates();
}

abstract interface class AiProposalRepository {
  Future<List<AiProposalVm>> listPending();
  Future<AiProposalVm?> getProposal(Id id);
  // 写路径：仅生成/处理 proposal，永不直接写正式账本。
  Future<ConfirmResultVm> approveAtomicGroup(Id groupId);
  Future<void> rejectAtomicGroup(Id groupId, {String? reason});

  /// 文本导入：AI 只生成候选 proposal，用户确认后才入账。
  Future<void> createFromText(String text);

  /// CSV 导入：逐行生成候选 atomic group；确认前不写账本。
  Future<void> createFromCsv(
    String csv, {
    Id? defaultAccountId,
    String? defaultCurrency,
  });

  /// 图片导入：图片只作为 evidence 生成候选；确认前不写账本。
  Future<void> createFromImage({
    required String fileName,
    required String imageBase64,
    String? mimeType,
  });

  /// 编辑候选：把（无金额的）文本候选补成结构化 movement，approve 前必需。仅 local_server。
  Future<void> editAtomicGroup(Id groupId, ManualRecordInput input);
}

abstract interface class SnapshotRepository {
  Future<NetWorthSnapshotVm?> getLatest();
  Future<List<NetWorthSnapshotVm>> listSnapshots();
  Future<NetWorthSnapshotVm> createManualSnapshot({required String reason});
}

/// 订阅管理：计划本身不写流水；charge-proposal 只生成待确认候选，确认后才动余额。
/// 所有写方法复用 DevApiClient 的幂等请求路径；能力由 canManageSubscriptions 门控。
abstract interface class SubscriptionRepository {
  Future<List<SubscriptionVm>> listSubscriptions();
  Future<List<SubscriptionVm>> listUpcomingSubscriptions({int days = 30});
  Future<SubscriptionVm> getSubscription(Id id);
  Future<SubscriptionVm> createSubscription(CreateSubscriptionInput input);
  Future<SubscriptionVm> updateSubscription(
    Id id,
    UpdateSubscriptionInput input,
  );

  /// 取消未来扣费（不删历史）。有待确认候选时服务端返回 409。
  Future<SubscriptionVm> cancelSubscription(Id id);

  /// 生成本期待确认扣费候选（pending_review）。返回 atomic group，交 AI 复核确认。
  /// 本期已有候选时服务端返回 409。
  Future<AiAtomicGroupVm> createChargeProposal(Id id);

  /// 到期扫描：为 nextChargeDate <= throughDate 的 trial/active 计划批量生成
  /// 待确认候选。limit（1–200）只限本次新建数量，skip 照常报告。
  /// 用户显式触发的命令；不自动确认、不扣款、不推进日期。
  Future<SubscriptionDueScanResultVm> scanDueChargeProposals({
    required IsoDate throughDate,
    int limit = 100,
  });
}
