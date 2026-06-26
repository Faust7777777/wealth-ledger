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

abstract interface class PortfolioRepository {
  Future<PortfolioOverviewVm> getOverview();
  Future<List<HoldingVm>> listHoldings();
  Future<List<HoldingVm>> listHoldingsByAccount(Id accountId);
  Future<AssetAllocationVm> getAssetAllocation();
}

abstract interface class MovementRepository {
  Future<List<MovementVm>> listRecentMovements({int limit = 20});
  Future<MovementVm?> getMovement(Id id);
}

abstract interface class DcaRepository {
  Future<List<DcaReminderVm>> listDueReminders();
  Future<List<DcaPlanVm>> listPlans();
  /// 「记录已执行」：只生成待确认候选记录；不下单、不转账、不连券商。
  Future<void> markExecutedAsProposal(Id reminderId);
}

abstract interface class QuoteRepository {
  Future<QuoteStatusSummaryVm> getQuoteSummary();
}

abstract interface class AiProposalRepository {
  Future<List<AiProposalVm>> listPending();
  Future<AiProposalVm?> getProposal(Id id);
  // 写路径：仅生成/处理 proposal，永不直接写正式账本。
  Future<void> approveAtomicGroup(Id groupId);
  Future<void> rejectAtomicGroup(Id groupId, {String? reason});
  /// 文本导入：AI 只生成候选 proposal，用户确认后才入账。
  Future<void> createFromText(String text);
}

abstract interface class SnapshotRepository {
  Future<NetWorthSnapshotVm?> getLatest();
  Future<List<NetWorthSnapshotVm>> listSnapshots();
}
