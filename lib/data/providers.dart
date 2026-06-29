// Wealth Ledger — Riverpod 注入：按 DataSourceMode 切 real_local / debug_fixture。
// 页面只 watch 这些 provider，不感知数据来源；fixture 仅在 demo 模式注入。
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/env.dart';
import 'api_mock_repositories.dart';
import 'auth_repositories.dart';
import 'auth_store.dart';
import 'auth_token_store_io.dart';
import 'fixture_repositories.dart';
import 'real_local_repositories.dart';
import 'repositories.dart';
import 'view_models.dart';

DataSourceMode _mode(Ref ref) =>
    ref.watch(appEnvironmentProvider).dataSourceMode;

final devApiClientProvider = Provider<DevApiClient>((ref) {
  final env = ref.watch(appEnvironmentProvider);
  return DevApiClient(
    env.apiBaseUrl,
    scenario: env.apiScenario,
    tokenStore: ref.watch(authTokenStoreProvider),
  );
});

final authTokenStoreProvider = Provider<AuthTokenStore>(
  (ref) => PlatformAuthTokenStore(),
);

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  if (_mode(ref) != DataSourceMode.localServer) {
    return const UnsupportedAuthRepository();
  }
  return LocalServerAuthRepository(ref.watch(devApiClientProvider));
});

class AuthController extends AsyncNotifier<AuthSessionVm?> {
  @override
  Future<AuthSessionVm?> build() async => ref
      .watch(authTokenStoreProvider)
      .read()
      .then(
        (stored) => stored == null
            ? null
            : AuthSessionVm(
                accessToken: stored.accessToken,
                refreshToken: stored.refreshToken,
                expiresAt: stored.expiresAt,
                deviceId: stored.deviceId,
              ),
      );

  Future<void> login({
    required String username,
    required String password,
    required String deviceName,
  }) async {
    state = const AsyncLoading<AuthSessionVm?>();
    try {
      final session = await ref
          .read(authRepositoryProvider)
          .login(
            username: username,
            password: password,
            deviceName: deviceName,
          );
      await ref.read(authTokenStoreProvider).write(session);
      state = AsyncData(session);
      ref.invalidate(authDevicesProvider);
    } catch (error, stackTrace) {
      state = AsyncError<AuthSessionVm?>(error, stackTrace);
      rethrow;
    }
  }

  Future<void> refresh() async {
    final current =
        state.asData?.value ?? await ref.read(authTokenStoreProvider).read();
    if (current == null) {
      throw StateError('尚未登录');
    }
    state = const AsyncLoading<AuthSessionVm?>();
    try {
      final session = await ref
          .read(authRepositoryProvider)
          .refresh(current.refreshToken);
      await ref.read(authTokenStoreProvider).write(session);
      state = AsyncData(session);
      ref.invalidate(authDevicesProvider);
    } catch (error, stackTrace) {
      state = AsyncError<AuthSessionVm?>(error, stackTrace);
      rethrow;
    }
  }

  Future<void> logout() async {
    final current =
        state.asData?.value ?? await ref.read(authTokenStoreProvider).read();
    if (current != null) {
      try {
        await ref.read(authRepositoryProvider).logout(current.refreshToken);
      } catch (_) {
        // Local logout must still clear tokens even if the dev server is down.
      }
    }
    await ref.read(authTokenStoreProvider).clear();
    state = const AsyncData(null);
    ref.invalidate(authDevicesProvider);
  }

  Future<void> revokeDevice(String deviceId) async {
    await ref.read(authRepositoryProvider).revokeDevice(deviceId);
    ref.invalidate(authDevicesProvider);
  }
}

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AuthSessionVm?>(AuthController.new);

final authDevicesProvider = FutureProvider<List<AuthDeviceVm>>((ref) async {
  final session = await ref.watch(authControllerProvider.future);
  if (session == null) return const [];
  return ref.watch(authRepositoryProvider).listDevices();
});

T _pick<T>(
  Ref ref, {
  required T Function() real,
  required T Function() fixture,
  required T Function() api,
}) => switch (_mode(ref)) {
  DataSourceMode.debugFixture => fixture(),
  DataSourceMode.localServer => api(),
  _ => real(),
};

// —— 仓库 provider（按 mode 选实现：real_local / debug_fixture / local_server）——
final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => _pick(
    ref,
    real: () => const RealLocalAccountRepository(),
    fixture: () => const FixtureAccountRepository(),
    api: () => LocalServerAccountRepository(ref.watch(devApiClientProvider)),
  ),
);
final taxonomyRepositoryProvider = Provider<TaxonomyRepository>(
  (ref) => _pick(
    ref,
    real: () => const RealLocalTaxonomyRepository(),
    fixture: () => const FixtureTaxonomyRepository(),
    api: () => LocalServerTaxonomyRepository(ref.watch(devApiClientProvider)),
  ),
);
final portfolioRepositoryProvider = Provider<PortfolioRepository>(
  (ref) => _pick(
    ref,
    real: () => const RealLocalPortfolioRepository(),
    fixture: () => const FixturePortfolioRepository(),
    api: () => LocalServerPortfolioRepository(ref.watch(devApiClientProvider)),
  ),
);
final movementRepositoryProvider = Provider<MovementRepository>(
  (ref) => _pick(
    ref,
    real: () => const RealLocalMovementRepository(),
    fixture: () => const FixtureMovementRepository(),
    api: () => LocalServerMovementRepository(ref.watch(devApiClientProvider)),
  ),
);
final dcaRepositoryProvider = Provider<DcaRepository>(
  (ref) => _pick(
    ref,
    real: () => const RealLocalDcaRepository(),
    fixture: () => const FixtureDcaRepository(),
    api: () => LocalServerDcaRepository(ref.watch(devApiClientProvider)),
  ),
);
final quoteRepositoryProvider = Provider<QuoteRepository>(
  (ref) => _pick(
    ref,
    real: () => const RealLocalQuoteRepository(),
    fixture: () => const FixtureQuoteRepository(),
    api: () => LocalServerQuoteRepository(ref.watch(devApiClientProvider)),
  ),
);
final aiProposalRepositoryProvider = Provider<AiProposalRepository>(
  (ref) => _pick(
    ref,
    real: () => const RealLocalAiProposalRepository(),
    fixture: () => const FixtureAiProposalRepository(),
    api: () => LocalServerAiProposalRepository(ref.watch(devApiClientProvider)),
  ),
);
final snapshotRepositoryProvider = Provider<SnapshotRepository>(
  (ref) => _pick(
    ref,
    real: () => const RealLocalSnapshotRepository(),
    fixture: () => const FixtureSnapshotRepository(),
    api: () => LocalServerSnapshotRepository(ref.watch(devApiClientProvider)),
  ),
);

// —— 功能数据 provider ——
final overviewProvider = FutureProvider<PortfolioOverviewVm>(
  (ref) => ref.watch(portfolioRepositoryProvider).getOverview(),
);
final accountsProvider = FutureProvider<List<AccountVm>>((ref) async {
  final all = await ref.watch(accountRepositoryProvider).listAccounts();
  return all.where((a) => !a.isArchived).toList(); // 归档账户不进默认列表
});
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
final categoriesProvider = FutureProvider<List<CategoryVm>>(
  (ref) => ref.watch(taxonomyRepositoryProvider).listCategories(),
);
final counterpartiesProvider = FutureProvider<List<CounterpartyVm>>(
  (ref) => ref.watch(taxonomyRepositoryProvider).listCounterparties(),
);

// —— 账户详情 family ——
final accountByIdProvider = FutureProvider.family<AccountVm?, String>(
  (ref, id) => ref.watch(accountRepositoryProvider).getAccount(id),
);
final holdingsByAccountProvider =
    FutureProvider.family<List<HoldingVm>, String>(
      (ref, id) =>
          ref.watch(portfolioRepositoryProvider).listHoldingsByAccount(id),
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

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);
