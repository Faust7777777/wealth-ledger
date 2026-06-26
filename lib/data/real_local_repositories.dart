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
  Future<AssetAllocationVm> getAssetAllocation() async => const AssetAllocationVm(
        slices: [],
        totalAssets: Money(amount: '0', currency: 'CNY'),
        totalLiabilities: Money(amount: '0', currency: 'CNY'),
        netWorth: Money(amount: '0', currency: 'CNY'),
      );
}

class RealLocalMovementRepository implements MovementRepository {
  const RealLocalMovementRepository();
  @override
  Future<List<MovementVm>> listRecentMovements({int limit = 20}) async => const [];
  @override
  Future<MovementVm?> getMovement(Id id) async => null;
  @override
  Future<MovementVm> createManualRecord(ManualRecordInput input) async =>
      throw UnsupportedError('real_local 暂不支持手动记账；请用 local_server');
  @override
  Future<MovementVm> createTransfer(TransferInput input) async =>
      throw UnsupportedError('real_local 暂不支持转账；请用 local_server');
}

class RealLocalDcaRepository implements DcaRepository {
  const RealLocalDcaRepository();
  @override
  Future<List<DcaReminderVm>> listDueReminders() async => const [];
  @override
  Future<List<DcaPlanVm>> listPlans() async => const [];
  @override
  Future<void> markExecutedAsProposal(Id reminderId) async =>
      throw UnsupportedError('real_local 暂不支持写入；请用 local_server 联调');
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
  @override
  Future<void> approveAtomicGroup(Id groupId) async =>
      throw UnsupportedError('real_local 暂不支持写入；请用 local_server 联调');
  @override
  Future<void> rejectAtomicGroup(Id groupId, {String? reason}) async =>
      throw UnsupportedError('real_local 暂不支持写入；请用 local_server 联调');
  @override
  Future<void> createFromText(String text) async =>
      throw UnsupportedError('real_local 暂不支持 AI 导入；请用 local_server 联调');
}

class RealLocalSnapshotRepository implements SnapshotRepository {
  const RealLocalSnapshotRepository();
  @override
  Future<NetWorthSnapshotVm?> getLatest() async => null;
  @override
  Future<List<NetWorthSnapshotVm>> listSnapshots() async => const [];
}
