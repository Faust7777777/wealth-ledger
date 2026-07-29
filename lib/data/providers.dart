// Wealth Ledger — Riverpod 注入：按 DataSourceMode 切 real_local / debug_fixture。
// 页面只 watch 这些 provider，不感知数据来源；fixture 仅在 demo 模式注入。
import 'dart:typed_data';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_endpoint_store.dart';
import '../core/env.dart';
import 'api_mock_repositories.dart';
import 'auth_repositories.dart';
import 'auth_store.dart';
import 'auth_token_store_io.dart';
import 'fixture_repositories.dart';
import 'real_local_repositories.dart';
import 'repositories.dart';
import 'view_models.dart';

final apiEndpointStoreProvider = Provider<ApiEndpointStore>(
  (ref) => PlatformApiEndpointStore(),
);

class RemoteApiEndpointController extends AsyncNotifier<String?> {
  @override
  Future<String?> build() => ref.watch(apiEndpointStoreProvider).read();

  Future<String> configure(String input) async {
    final normalized = normalizeHttpsApiOrigin(input);
    await ref.read(apiEndpointStoreProvider).write(normalized);
    state = AsyncData(normalized);
    return normalized;
  }

  Future<void> clear() async {
    state = const AsyncLoading<String?>();
    await ref.read(apiEndpointStoreProvider).clear();
    state = const AsyncData(null);
  }
}

final remoteApiEndpointProvider =
    AsyncNotifierProvider<RemoteApiEndpointController, String?>(
      RemoteApiEndpointController.new,
    );

final effectiveAppEnvironmentProvider = Provider<AppEnvironment>((ref) {
  final base = ref.watch(appEnvironmentProvider);
  if (base.dataSourceMode != DataSourceMode.apiRemote) return base;
  final saved = ref.watch(remoteApiEndpointProvider).value;
  return saved == null ? base : base.copyWith(apiBaseUrl: saved);
});

DataSourceMode _mode(Ref ref) =>
    ref.watch(effectiveAppEnvironmentProvider).dataSourceMode;

final devApiClientProvider = Provider<DevApiClient>((ref) {
  final env = ref.watch(effectiveAppEnvironmentProvider);
  return DevApiClient(
    env.apiBaseUrl,
    scenario: env.apiScenario,
    tokenStore: ref.watch(authTokenStoreProvider),
    // 延迟 read：避免与 authRepositoryProvider 形成构建期循环依赖。
    onSessionExpired: () =>
        ref.read(authControllerProvider.notifier).markSessionExpired(),
  );
});

final authTokenStoreProvider = Provider<AuthTokenStore>(
  (ref) => PlatformAuthTokenStore(),
);

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  if (!ref.watch(effectiveAppEnvironmentProvider).isApiBacked) {
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
      // 登录前 bootstrap 会 401 → capabilities 回落只读；登录后必须重取。
      ref.invalidate(capabilitiesProvider);
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
      ref.invalidate(capabilitiesProvider);
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
    // 登出后写能力随会话失效，重取（auth-on 时会回落只读）。
    ref.invalidate(capabilitiesProvider);
  }

  /// 会话已被服务端判定失效（refresh 也 401）：只清本地登录态，不再调用服务端。
  /// 幂等：已经是未登录就直接返回。
  Future<void> markSessionExpired() async {
    if (state.asData?.value == null && state is AsyncData) return;
    await ref.read(authTokenStoreProvider).clear();
    state = const AsyncData(null);
    ref.invalidate(authDevicesProvider);
    ref.invalidate(capabilitiesProvider);
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
  DataSourceMode.localServer || DataSourceMode.apiRemote => api(),
  DataSourceMode.realLocal => real(),
};

// —— 仓库 provider（按 mode 选实现：real_local / debug_fixture / local_server）——
final ledgerRepositoryProvider = Provider<LedgerRepository>(
  (ref) => _pick(
    ref,
    real: () => const RealLocalLedgerRepository(),
    fixture: () => const FixtureLedgerRepository(),
    api: () => LocalServerLedgerRepository(ref.watch(devApiClientProvider)),
  ),
);

/// 账本能力（写入口 gating 的唯一口径）。UI 用 [writeCapabilities] 取值，
/// 加载中 / 请求失败一律回落到 locked（fail-closed 只读）。
final capabilitiesProvider = FutureProvider<LedgerCapabilitiesVm>(
  (ref) => ref.watch(ledgerRepositoryProvider).getCapabilities(),
);

extension WriteCapabilitiesX on WidgetRef {
  LedgerCapabilitiesVm get writeCapabilities =>
      watch(capabilitiesProvider).asData?.value ?? LedgerCapabilitiesVm.locked;
}

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
final instrumentRepositoryProvider = Provider<InstrumentRepository>(
  (ref) => _pick(
    ref,
    real: () => const RealLocalInstrumentRepository(),
    fixture: () => const FixtureInstrumentRepository(),
    api: () => LocalServerInstrumentRepository(ref.watch(devApiClientProvider)),
  ),
);
final loanRepositoryProvider = Provider<LoanRepository>(
  (ref) => _pick(
    ref,
    real: () => const RealLocalLoanRepository(),
    fixture: () => const FixtureLoanRepository(),
    api: () => LocalServerLoanRepository(ref.watch(devApiClientProvider)),
  ),
);
final agentRepositoryProvider = Provider<AgentRepository>(
  (ref) => _pick(
    ref,
    real: () => const RealLocalAgentRepository(),
    fixture: () => const FixtureAgentRepository(),
    api: () => LocalServerAgentRepository(ref.watch(devApiClientProvider)),
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
final instrumentsProvider = FutureProvider<List<InstrumentVm>>(
  (ref) => ref.watch(instrumentRepositoryProvider).listInstruments(),
);
final fxRatesProvider = FutureProvider<List<FxRateVm>>(
  (ref) => ref.watch(quoteRepositoryProvider).listFxRates(),
);
final agentStatusProvider = FutureProvider<AgentStatusVm>(
  (ref) => ref.watch(agentRepositoryProvider).getStatus(),
);
final agentModelsProvider = FutureProvider<List<AgentModelVm>>(
  (ref) => ref.watch(agentRepositoryProvider).listModels(),
);

/// 模型连接列表。失败要能看见错误并重试，因此关掉自动重试
/// （Riverpod 3 默认会一直重试并把 provider 留在 loading）。
final agentProvidersProvider = FutureProvider<List<AgentProviderVm>>(
  (ref) => ref.watch(agentRepositoryProvider).listProviders(),
  retry: (_, _) => null,
);
final agentConversationsProvider = FutureProvider<List<AgentConversationVm>>(
  (ref) => ref.watch(agentRepositoryProvider).listConversations(),
);
final agentMemoriesProvider = FutureProvider<List<AgentMemoryVm>>(
  (ref) => ref.watch(agentRepositoryProvider).listMemories(),
);
final agentAutomationsProvider = FutureProvider<List<AgentAutomationVm>>(
  (ref) => ref.watch(agentRepositoryProvider).listAutomations(),
);
final agentNotificationsProvider = FutureProvider<List<AgentNotificationVm>>(
  (ref) => ref.watch(agentRepositoryProvider).listNotifications(),
);

/// 未读数：入口只显示这个数字。
final agentUnreadNotificationCountProvider = Provider<int>((ref) {
  final list = ref.watch(agentNotificationsProvider).asData?.value ?? const [];
  return list.where((n) => n.isUnread).length;
});

final agentQuoteCandidatesProvider =
    FutureProvider<List<AgentQuoteCandidateVm>>(
      (ref) => ref.watch(agentRepositoryProvider).listQuoteCandidates(),
    );

/// 附件安全元数据：历史消息先读它再决定怎么呈现，避免把非图片字节交给解码器。
final agentAttachmentMetaProvider =
    FutureProvider.family<AgentAttachmentVm, String>(
      (ref, attachmentId) =>
          ref.watch(agentRepositoryProvider).getAttachment(attachmentId),
      retry: (_, _) => null,
    );

/// 附件原图字节（消息历史与重启后恢复预览）；失败不自动退避重试，由 UI 决定。
final agentAttachmentBytesProvider = FutureProvider.family<Uint8List, String>(
  (ref, attachmentId) =>
      ref.watch(agentRepositoryProvider).getAttachmentContent(attachmentId),
  retry: (_, _) => null,
);

/// 桌面右栏是否展开（移动端走全屏路由，不用这个开关）。
class AgentPanelVisibility extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
  void close() => state = false;
}

final agentPanelOpenProvider = NotifierProvider<AgentPanelVisibility, bool>(
  AgentPanelVisibility.new,
);
final liabilityPositionsProvider = FutureProvider<List<LiabilityPositionVm>>(
  (ref) => ref.watch(loanRepositoryProvider).listLiabilityPositions(),
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

// —— 订阅管理 ——
// 计划本身不写流水；charge-proposal 只生成候选，走 AI 复核确认后才动余额。
final subscriptionRepositoryProvider = Provider<SubscriptionRepository>(
  (ref) => _pick(
    ref,
    real: () => const RealLocalSubscriptionRepository(),
    fixture: () => const FixtureSubscriptionRepository(),
    api: () =>
        LocalServerSubscriptionRepository(ref.watch(devApiClientProvider)),
  ),
);
final subscriptionsProvider = FutureProvider<List<SubscriptionVm>>(
  (ref) => ref.watch(subscriptionRepositoryProvider).listSubscriptions(),
);

/// 即将扣费（默认 30 天窗口），用于「财务管理」入口的到期提醒。
final upcomingSubscriptionsProvider = FutureProvider<List<SubscriptionVm>>(
  (ref) =>
      ref.watch(subscriptionRepositoryProvider).listUpcomingSubscriptions(),
);
final subscriptionByIdProvider = FutureProvider.family<SubscriptionVm, String>(
  (ref, id) => ref.watch(subscriptionRepositoryProvider).getSubscription(id),
);

extension SubscriptionRefreshX on WidgetRef {
  /// 订阅本体写成功后（新建/编辑/取消）：精确失效列表、即将扣费、该订阅详情。
  void refreshSubscriptions({String? id}) {
    invalidate(subscriptionsProvider);
    invalidate(upcomingSubscriptionsProvider);
    if (id != null) invalidate(subscriptionByIdProvider(id));
  }

  /// 生成扣费候选成功后：订阅视图外还要失效 AI 待确认（候选进了复核队列）
  /// 与首页聚合（aiPendingCount 变了）。
  void refreshAfterChargeProposal({required String id}) {
    refreshSubscriptions(id: id);
    invalidate(aiPendingProvider);
    invalidate(overviewProvider);
  }

  /// 到期扫描成功后：批量候选可能涉及多个订阅，全量失效订阅视图、
  /// AI 待确认与首页聚合（pending count）。
  void refreshAfterDueScan() {
    refreshSubscriptions();
    invalidate(aiPendingProvider);
    invalidate(overviewProvider);
  }
}

extension InvestmentTradeRefreshX on WidgetRef {
  /// 投资成交确认成功后的刷新范围：账户/持仓/首页/构成/流水/该 movement 详情；
  /// 快照与异常遵循现有 snapshotInvalidated 语义（ledgerWrite 视为等效信号）。
  void refreshAfterInvestmentTrade(
    ConfirmResultVm result, {
    String? holdingAccountId,
  }) {
    invalidate(recentMovementsProvider);
    invalidate(overviewProvider);
    invalidate(accountsProvider);
    invalidate(holdingsProvider);
    invalidate(allocationProvider);
    for (final id in result.confirmedMovementIds) {
      invalidate(movementByIdProvider(id));
    }
    if (holdingAccountId != null) {
      invalidate(holdingsByAccountProvider(holdingAccountId));
    }
    if (result.ledgerWrite || result.snapshotInvalidated) {
      invalidate(snapshotsProvider);
      invalidate(anomaliesProvider);
    }
  }
}

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
