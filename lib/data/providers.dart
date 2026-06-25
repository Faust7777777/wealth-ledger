// Wealth Ledger — Riverpod 注入：按 DataSourceMode 切 real_local / debug_fixture。
// 页面只 watch 这些 provider，不感知数据来源；fixture 仅在 demo 模式注入。
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/env.dart';
import 'fixture_repositories.dart';
import 'real_local_repositories.dart';
import 'repositories.dart';
import 'view_models.dart';

bool _useFixture(Ref ref) =>
    ref.watch(appEnvironmentProvider).dataSourceMode == DataSourceMode.debugFixture;

// —— 仓库 provider（按 mode 选实现）——
final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => _useFixture(ref) ? const FixtureAccountRepository() : const RealLocalAccountRepository(),
);
final portfolioRepositoryProvider = Provider<PortfolioRepository>(
  (ref) => _useFixture(ref) ? const FixturePortfolioRepository() : const RealLocalPortfolioRepository(),
);
final movementRepositoryProvider = Provider<MovementRepository>(
  (ref) => _useFixture(ref) ? const FixtureMovementRepository() : const RealLocalMovementRepository(),
);
final dcaRepositoryProvider = Provider<DcaRepository>(
  (ref) => _useFixture(ref) ? const FixtureDcaRepository() : const RealLocalDcaRepository(),
);
final quoteRepositoryProvider = Provider<QuoteRepository>(
  (ref) => _useFixture(ref) ? const FixtureQuoteRepository() : const RealLocalQuoteRepository(),
);
final aiProposalRepositoryProvider = Provider<AiProposalRepository>(
  (ref) => _useFixture(ref) ? const FixtureAiProposalRepository() : const RealLocalAiProposalRepository(),
);
final snapshotRepositoryProvider = Provider<SnapshotRepository>(
  (ref) => _useFixture(ref) ? const FixtureSnapshotRepository() : const RealLocalSnapshotRepository(),
);

// —— 功能数据 provider ——
final overviewProvider = FutureProvider<PortfolioOverviewVm>(
  (ref) => ref.watch(portfolioRepositoryProvider).getOverview(),
);
final accountsProvider = FutureProvider<List<AccountVm>>(
  (ref) => ref.watch(accountRepositoryProvider).listAccounts(),
);
final anomaliesProvider = FutureProvider<List<AccountAnomalyVm>>(
  (ref) => ref.watch(accountRepositoryProvider).listAnomalies(),
);
final liabilitiesProvider = FutureProvider<List<AccountVm>>((ref) async {
  final all = await ref.watch(accountRepositoryProvider).listAccounts();
  return all.where((a) => a.isLiability).toList();
});
final holdingsProvider = FutureProvider<List<HoldingVm>>(
  (ref) => ref.watch(portfolioRepositoryProvider).listHoldings(),
);
final allocationProvider = FutureProvider<AssetAllocationVm>(
  (ref) => ref.watch(portfolioRepositoryProvider).getAssetAllocation(),
);
final dueRemindersProvider = FutureProvider<List<DcaReminderVm>>(
  (ref) => ref.watch(dcaRepositoryProvider).listDueReminders(),
);
final dcaPlansProvider = FutureProvider<List<DcaPlanVm>>(
  (ref) => ref.watch(dcaRepositoryProvider).listPlans(),
);
final aiPendingProvider = FutureProvider<List<AiProposalVm>>(
  (ref) => ref.watch(aiProposalRepositoryProvider).listPending(),
);
final recentMovementsProvider = FutureProvider<List<MovementVm>>(
  (ref) => ref.watch(movementRepositoryProvider).listRecentMovements(),
);
final snapshotsProvider = FutureProvider<List<NetWorthSnapshotVm>>(
  (ref) => ref.watch(snapshotRepositoryProvider).listSnapshots(),
);

// —— 账户详情 family ——
final accountByIdProvider = FutureProvider.family<AccountVm?, String>(
  (ref, id) => ref.watch(accountRepositoryProvider).getAccount(id),
);
final holdingsByAccountProvider = FutureProvider.family<List<HoldingVm>, String>(
  (ref, id) => ref.watch(portfolioRepositoryProvider).listHoldingsByAccount(id),
);
final movementByIdProvider = FutureProvider.family<MovementVm?, String>(
  (ref, id) => ref.watch(movementRepositoryProvider).getMovement(id),
);

// —— 主题（深色默认）——
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.dark;
  void toggle() =>
      state = state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
  void set(ThemeMode mode) => state = mode;
}

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);
