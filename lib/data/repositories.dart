// Wealth Ledger — Repository 抽象接口（前端唯一数据入口）。
// 命名对齐 DATA_SCHEMA_V1 §14；方法对齐 APPLICATION_INTERFACES_V1 的读路径。
// 第一阶段只暴露读方法 + 空/隔离实现；写路径（confirmAtomicGroup / approve /
// markExecutedAsProposal 等）在后续批次补，并仍走"候选→确认"。
import 'view_models.dart';
import '../core/types.dart';

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
  Future<List<CounterpartyVm>> listCounterparties();
  Future<CounterpartyVm> createCounterparty(CreateCounterpartyInput input);

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
}

abstract interface class MovementRepository {
  Future<List<MovementVm>> listRecentMovements({int limit = 20});
  Future<MovementVm?> getMovement(Id id);

  /// 手动记账：草稿 → 提交复核 → 确认入账（候选→确认，全程用户主动发起）。
  /// 仅 local_server 真实账本；real_local / DEMO 不支持。
  Future<MovementVm> createManualRecord(ManualRecordInput input);

  /// 转账：账户间转移（双分录草稿 → 复核 → 确认）。仅 local_server。
  Future<MovementVm> createTransfer(TransferInput input);

  /// 余额观察/校准：对差额生成 adjustment 候选并确认入账。仅 local_server。
  Future<MovementVm> reconcileBalance(ReconcileInput input);

  /// 已确认记录更正：只生成 correction 候选；确认前不改原记录、不影响余额。
  Future<void> createCorrectionProposal(CreateCorrectionInput input);
}

abstract interface class DcaRepository {
  Future<List<DcaReminderVm>> listDueReminders();
  Future<List<DcaPlanVm>> listPlans();
  Future<DcaPlanVm> createPlan(CreateDcaPlanInput input);

  /// 「记录已执行」：只生成待确认候选记录；不下单、不转账、不连券商。
  Future<void> markExecutedAsProposal(Id reminderId);
  Future<void> skipReminder(Id reminderId);
  Future<void> snoozeReminder(Id reminderId, {required IsoDate until});
}

abstract interface class QuoteRepository {
  Future<QuoteStatusSummaryVm> getQuoteSummary();
  Future<QuoteRefreshResultVm> refreshQuotes({required String mode});
}

abstract interface class AiProposalRepository {
  Future<List<AiProposalVm>> listPending();
  Future<AiProposalVm?> getProposal(Id id);
  // 写路径：仅生成/处理 proposal，永不直接写正式账本。
  Future<void> approveAtomicGroup(Id groupId);
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
