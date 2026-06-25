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
}

abstract interface class PortfolioRepository {
  Future<PortfolioOverviewVm> getOverview();
  Future<List<HoldingVm>> listHoldings();
  Future<List<HoldingVm>> listHoldingsByAccount(Id accountId);
}

abstract interface class MovementRepository {
  Future<List<MovementVm>> listRecentMovements({int limit = 20});
  Future<MovementVm?> getMovement(Id id);
}

abstract interface class DcaRepository {
  Future<List<DcaReminderVm>> listDueReminders();
}

abstract interface class QuoteRepository {
  Future<QuoteStatusSummaryVm> getQuoteSummary();
}

abstract interface class AiProposalRepository {
  Future<List<AiProposalVm>> listPending();
  Future<AiProposalVm?> getProposal(Id id);
}

abstract interface class SnapshotRepository {
  Future<NetWorthSnapshotVm?> getLatest();
}
