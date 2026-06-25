// Wealth Ledger — real_local 仓库：默认空账本。
// 不加载 fixture、不写真实账本、不报错、不接真实行情/AI/同步。
// TODO(LOCAL_LEDGER_FORMAT_V1): 接真实本地账本（由后端线 / Rust core 提供）；当前一律返回空。
import '../core/types.dart';
import 'repositories.dart';
import 'view_models.dart';

class RealLocalAccountRepository implements AccountRepository {
  const RealLocalAccountRepository();
  @override
  Future<List<AccountVm>> listAccounts() async => const [];
  @override
  Future<AccountVm?> getAccount(Id id) async => null;
  @override
  Future<List<AccountAnomalyVm>> listAnomalies() async => const [];
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
}

class RealLocalMovementRepository implements MovementRepository {
  const RealLocalMovementRepository();
  @override
  Future<List<MovementVm>> listRecentMovements({int limit = 20}) async => const [];
  @override
  Future<MovementVm?> getMovement(Id id) async => null;
}

class RealLocalDcaRepository implements DcaRepository {
  const RealLocalDcaRepository();
  @override
  Future<List<DcaReminderVm>> listDueReminders() async => const [];
}

class RealLocalQuoteRepository implements QuoteRepository {
  const RealLocalQuoteRepository();
  @override
  Future<QuoteStatusSummaryVm> getQuoteSummary() async => const QuoteStatusSummaryVm();
}

class RealLocalAiProposalRepository implements AiProposalRepository {
  const RealLocalAiProposalRepository();
  @override
  Future<List<AiProposalVm>> listPending() async => const [];
  @override
  Future<AiProposalVm?> getProposal(Id id) async => null;
}

class RealLocalSnapshotRepository implements SnapshotRepository {
  const RealLocalSnapshotRepository();
  @override
  Future<NetWorthSnapshotVm?> getLatest() async => null;
}
