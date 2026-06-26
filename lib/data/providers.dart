// Wealth Ledger — Riverpod 注入：按 DataSourceMode 切 real_local / debug_fixture。
// 页面只 watch 这些 provider，不感知数据来源；fixture 仅在 demo 模式注入。
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/env.dart';
import 'api_mock_repositories.dart';
import 'fixture_repositories.dart';
import 'real_local_repositories.dart';
import 'repositories.dart';
import 'view_models.dart';

DataSourceMode _mode(Ref ref) => ref.watch(appEnvironmentProvider).dataSourceMode;

final devApiClientProvider = Provider<DevApiClient>((ref) {
  final env = ref.watch(appEnvironmentProvider);
  return DevApiClient(env.apiBaseUrl, scenario: env.apiScenario);
});

T _pick<T>(
  Ref ref, {
  required T Function() real,
  required T Function() fixture,
  required T Function() api,
}) =>
    switch (_mode(ref)) {
      DataSourceMode.debugFixture => fixture(),
      DataSourceMode.localServer => api(),
      _ => real(),
    };

// —— 仓库 provider（按 mode 选实现：real_local / debug_fixture / local_server）——
final accountRepositoryProvider = Provider<AccountRepository>((ref) => _pick(
      ref,
      real: () => const RealLocalAccountRepository(),
      fixture: () => const FixtureAccountRepository(),
      api: () => LocalServerAccountRepository(ref.watch(devApiClientProvider)),
    ));
final portfolioRepositoryProvider = Provider<PortfolioRepository>((ref) => _pick(
      ref,
      real: () => const RealLocalPortfolioRepository(),
      fixture: () => const FixturePortfolioRepository(),
      api: () => LocalServerPortfolioRepository(ref.watch(devApiClientProvider)),
    ));
final movementRepositoryProvider = Provider<MovementRepository>((ref) => _pick(
      ref,
      real: () => const RealLocalMovementRepository(),
      fixture: () => const FixtureMovementRepository(),
      api: () => LocalServerMovementRepository(ref.watch(devApiClientProvider)),
    ));
final dcaRepositoryProvider = Provider<DcaRepository>((ref) => _pick(
      ref,
      real: () => const RealLocalDcaRepository(),
      fixture: () => const FixtureDcaRepository(),
      api: () => LocalServerDcaRepository(ref.watch(devApiClientProvider)),
    ));
final quoteRepositoryProvider = Provider<QuoteRepository>((ref) => _pick(
      ref,
      real: () => const RealLocalQuoteRepository(),
      fixture: () => const FixtureQuoteRepository(),
      api: () => LocalServerQuoteRepository(ref.watch(devApiClientProvider)),
    ));
final aiProposalRepositoryProvider = Provider<AiProposalRepository>((ref) => _pick(
      ref,
      real: () => const RealLocalAiProposalRepository(),
      fixture: () => const FixtureAiProposalRepository(),
      api: () => LocalServerAiProposalRepository(ref.watch(devApiClientProvider)),
    ));
final snapshotRepositoryProvider = Provider<SnapshotRepository>((ref) => _pick(
      ref,
      real: () => const RealLocalSnapshotRepository(),
      fixture: () => const FixtureSnapshotRepository(),
      api: () => LocalServerSnapshotRepository(ref.watch(devApiClientProvider)),
    ));

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
