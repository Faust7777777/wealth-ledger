// 统一可用性回归（2026-07-27 前端清单 §4）：首页、账户详情（含持仓行）、
// AI 导入（文本/图片/CSV）与 AI Review 在 360 / 1200 / 1440 宽度下均无溢出。
// 只断言"没有布局异常"，不锁死具体像素，避免变成脆弱的视觉回归。
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/account_detail_page.dart';
import 'package:finwealth/features/ai_import_csv_page.dart';
import 'package:finwealth/features/ai_import_image_page.dart';
import 'package:finwealth/features/ai_import_text_page.dart';
import 'package:finwealth/features/ai_review_page.dart';
import 'package:finwealth/features/overview_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _caps = LedgerCapabilitiesVm(
  dataSourceMode: 'local_server',
  canWriteConfirmedLedger: true,
  canCreateAccount: true,
  canRecordMovement: true,
  canConfirmProposal: true,
  canPersistPendingProposal: true,
  proposalPersistence: 'file',
);

const _account = AccountVm(
  id: 'a_okx',
  displayName: 'OKX 交易所账户（长名称用于挤压布局）',
  accountType: AccountType.exchange,
  isLiability: false,
  balanceMode: 'mixed',
  defaultCurrency: 'USDT',
  cashBalances: {'USDT': '123.45', 'CNY': '1000.00'},
);

const _holdings = [
  HoldingVm(
    id: 'h_btc',
    accountId: 'a_okx',
    instrumentId: 'inst_btc',
    symbol: 'BTC',
    displayName: 'Bitcoin',
    quantity: '0.00076078',
    quoteStatus: QuoteStatus.unpriceable,
  ),
  HoldingVm(
    id: 'h_eth',
    accountId: 'a_okx',
    instrumentId: 'inst_eth',
    symbol: 'ETH',
    displayName: 'Ethereum',
    quantity: '0.25',
    quoteStatus: QuoteStatus.fresh,
    costBasisTotal: Money(amount: '4200.00', currency: 'CNY'),
    marketValue: ValuedMoney(
      amount: '4800.00',
      currency: 'CNY',
      asOf: '2026-07-27T00:00:00Z',
      quality: ValueQuality.estimated,
    ),
    unrealizedPnl: Money(amount: '600.00', currency: 'CNY'),
  ),
];

final _overview = PortfolioOverviewVm(
  latestSnapshot: const NetWorthSnapshotVm(
    id: 'snap_1',
    snapshotAt: '2026-07-27T00:00:00Z',
    grossAssets: Money(amount: '253900.00', currency: 'CNY'),
    totalLiabilities: Money(amount: '9466.77', currency: 'CNY'),
    netWorth: Money(amount: '244433.23', currency: 'CNY'),
    quality: ValueQuality.incomplete,
  ),
  pendingSummary: const PendingSummaryVm(
    aiPendingCount: 2,
    accountAnomalyCount: 1,
    dcaDueCount: 1,
    inTransitCount: 1,
    quoteProblemCount: 3,
  ),
  quoteStatusSummary: const QuoteStatusSummaryVm(freshCount: 8, staleCount: 2),
  primaryHoldings: _holdings,
  recentMovements: const [
    MovementVm(
      id: 'mov_1',
      atomicGroupId: 'ag_1',
      type: MovementType.expense,
      status: MovementStatus.confirmed,
      title: '外卖平台（很长的标题用于挤压窄屏布局）',
      occurredAt: '2026-07-27T00:00:00Z',
      displayAmount: Money(amount: '20.00', currency: 'CNY'),
    ),
  ],
);

const _allocation = AssetAllocationVm(
  slices: [
    AllocationSliceVm(
      category: '现金与活期',
      percent: '30.5',
      value: Money(amount: '77900.45', currency: 'CNY'),
    ),
    AllocationSliceVm(
      category: '权益类',
      percent: '69.5',
      value: Money(amount: '176000.00', currency: 'CNY'),
    ),
  ],
  totalAssets: Money(amount: '253900.45', currency: 'CNY'),
  totalLiabilities: Money(amount: '9466.77', currency: 'CNY'),
  netWorth: Money(amount: '244433.68', currency: 'CNY'),
);

final _proposals = [
  const AiProposalVm(
    id: 'prop_1',
    status: AiProposalStatus.pending,
    sourceLabel: '文本输入',
    summary: 'AI 新增 1 笔消费',
    groups: [
      AiAtomicGroupVm(
        id: 'ag_create',
        title: '新增：午餐',
        operation: AiOperation.create,
        status: AiGroupStatus.pending,
        proposedMovement: MovementVm(
          id: 'mov_new',
          atomicGroupId: 'ag_create',
          type: MovementType.expense,
          status: MovementStatus.pendingReview,
          title: '午餐',
          occurredAt: '2026-07-27T12:30:00+08:00',
          displayAmount: Money(amount: '18', currency: 'CNY'),
          entries: [
            MovementEntryVm(
              accountId: 'a_okx',
              amount: '18',
              currency: 'CNY',
              direction: 'out',
              role: 'source',
            ),
          ],
        ),
      ),
      AiAtomicGroupVm(
        id: 'ag_incomplete',
        title: '文本：待补全',
        operation: AiOperation.create,
        status: AiGroupStatus.pending,
        isValid: false,
      ),
    ],
  ),
];

Widget _host(Widget page) => ProviderScope(
  overrides: [
    capabilitiesProvider.overrideWith((ref) async => _caps),
    overviewProvider.overrideWith((ref) async => _overview),
    accountsProvider.overrideWith((ref) async => const [_account]),
    holdingsProvider.overrideWith((ref) async => _holdings),
    holdingsByAccountProvider('a_okx').overrideWith((ref) async => _holdings),
    accountByIdProvider('a_okx').overrideWith((ref) async => _account),
    allocationProvider.overrideWith((ref) async => _allocation),
    recentMovementsProvider.overrideWith(
      (ref) async => _overview.recentMovements,
    ),
    subscriptionsProvider.overrideWith((ref) async => const <SubscriptionVm>[]),
    upcomingSubscriptionsProvider.overrideWith(
      (ref) async => const <SubscriptionVm>[],
    ),
    liabilityPositionsProvider.overrideWith(
      (ref) async => const <LiabilityPositionVm>[],
    ),
    aiPendingProvider.overrideWith((ref) async => _proposals),
  ],
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => page),
        GoRoute(path: '/ai-edit/:id', builder: (_, _) => const Placeholder()),
        GoRoute(path: '/ai-review', builder: (_, _) => const Placeholder()),
      ],
    ),
  ),
);

void main() {
  final pages = <String, Widget>{
    '首页': const Scaffold(body: OverviewPage()),
    '账户详情（含持仓行）': const AccountDetailPage(accountId: 'a_okx'),
    'AI 导入 · 文本': const AiImportTextPage(),
    'AI 导入 · 图片': const AiImportImagePage(),
    'AI 导入 · CSV': const AiImportCsvPage(),
    'AI Review': const AiReviewPage(),
  };

  for (final entry in pages.entries) {
    testWidgets('${entry.key}：360 / 1200 / 1440 宽无溢出', (tester) async {
      for (final size in const [
        Size(360, 900),
        Size(1200, 800),
        Size(1440, 900),
      ]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_host(entry.value));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '${entry.key} @ ${size.width.toInt()}',
        );
      }
    });
  }
}
