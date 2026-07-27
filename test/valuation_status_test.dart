// 权威估值问题接口（2026-07-18 任务单）：
// 面板只消费 GET /v1/portfolio/valuation-issues；多跳 FX 可用时不得误报缺少路径；
// 缺报价报 missing_quote 而非 missing_fx_path；空列表隐藏入口；加载失败保留入口并可重试。
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/overview_page.dart';
import 'package:finwealth/features/valuation_status_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Map<String, dynamic> _issueJson({
  required String id,
  required String assetLabel,
  required String quantity,
  required String status,
  required String reason,
  String accountName = 'OKX',
  String assetKind = 'holding',
  String sourceCurrency = 'USDT',
  String targetCurrency = 'CNY',
  String? asOf,
}) => {
  'id': id,
  'accountId': 'acct_okx',
  'accountName': accountName,
  'assetKind': assetKind,
  'assetId': 'inst_$assetLabel',
  'assetLabel': assetLabel,
  'quantity': quantity,
  'quantityUnit': assetLabel,
  'status': status,
  'reason': reason,
  'sourceCurrency': sourceCurrency,
  'targetCurrency': targetCurrency,
  'asOf': ?asOf,
};

ValuationIssueVm _issue({
  required String assetLabel,
  required String quantity,
  required ValuationIssueStatus status,
  required ValuationIssueReason reason,
  String accountName = 'OKX',
  String sourceCurrency = 'USDT',
}) => ValuationIssueVm(
  id: 'valuation_holding_acct_okx_$assetLabel',
  accountId: 'acct_okx',
  accountName: accountName,
  assetKind: ValuationAssetKind.holding,
  assetId: 'inst_$assetLabel',
  assetLabel: assetLabel,
  quantity: quantity,
  quantityUnit: assetLabel,
  status: status,
  reason: reason,
  sourceCurrency: sourceCurrency,
  targetCurrency: 'CNY',
);

PortfolioOverviewVm _overview({
  int stale = 0,
  int unpriceable = 0,
  int aiPending = 0,
}) => PortfolioOverviewVm(
  latestSnapshot: NetWorthSnapshotVm(
    id: 'snap_1',
    snapshotAt: '2026-07-27T00:00:00Z',
    grossAssets: const Money(amount: '1000.00', currency: 'CNY'),
    totalLiabilities: const Money(amount: '0', currency: 'CNY'),
    netWorth: const Money(amount: '1000.00', currency: 'CNY'),
    quality: unpriceable > 0 ? ValueQuality.incomplete : ValueQuality.exact,
  ),
  pendingSummary: PendingSummaryVm(
    aiPendingCount: aiPending,
    quoteProblemCount: stale + unpriceable,
  ),
  quoteStatusSummary: QuoteStatusSummaryVm(
    freshCount: 1,
    staleCount: stale,
    unpriceableCount: unpriceable,
  ),
  primaryHoldings: const [],
  recentMovements: const [],
);

class _FakeQuoteRepo implements QuoteRepository {
  _FakeQuoteRepo({this.failRefresh = false});
  final bool failRefresh;
  int refreshCalls = 0;

  @override
  Future<QuoteStatusSummaryVm> getQuoteSummary() async =>
      const QuoteStatusSummaryVm();
  @override
  Future<QuoteRefreshResultVm> refreshQuotes({required String mode}) async {
    refreshCalls += 1;
    if (failRefresh) throw Exception('网络不可用');
    return QuoteRefreshResultVm(
      status: 'success',
      completedAt: DateTime.now().toUtc().toIso8601String(),
    );
  }
}

/// 计数用假仓库：确认面板只走 valuation-issues，且失败后能重试成功。
class _CountingPortfolioRepo implements PortfolioRepository {
  _CountingPortfolioRepo(this.pages);
  final List<List<ValuationIssueVm>?> pages; // null 表示该次调用抛错
  int calls = 0;

  @override
  Future<List<ValuationIssueVm>> listValuationIssues() async {
    final page = pages[calls.clamp(0, pages.length - 1)];
    calls += 1;
    if (page == null) throw Exception('network');
    return page;
  }

  @override
  Future<PortfolioOverviewVm> getOverview() async => _overview();
  @override
  Future<List<HoldingVm>> listHoldings() async => const [];
  @override
  Future<List<HoldingVm>> listHoldingsByAccount(Id accountId) async => const [];
  @override
  Future<AssetAllocationVm> getAssetAllocation() async =>
      const AssetAllocationVm(
        slices: [],
        totalAssets: Money(amount: '1000.00', currency: 'CNY'),
        totalLiabilities: Money(amount: '0', currency: 'CNY'),
        netWorth: Money(amount: '1000.00', currency: 'CNY'),
      );
  @override
  Future<AiAtomicGroupVm> proposeHoldingAdjustment(
    Id accountId,
    HoldingAdjustmentInput input,
  ) async => throw UnsupportedError('unused');
}

Widget _host({
  required PortfolioOverviewVm overview,
  List<ValuationIssueVm> issues = const [],
  QuoteRepository? quoteRepo,
  PortfolioRepository? portfolioRepo,
}) => ProviderScope(
  overrides: [
    overviewProvider.overrideWith((ref) async => overview),
    accountsProvider.overrideWith((ref) async => const <AccountVm>[]),
    holdingsProvider.overrideWith((ref) async => const <HoldingVm>[]),
    allocationProvider.overrideWith(
      (ref) async => const AssetAllocationVm(
        slices: [],
        totalAssets: Money(amount: '1000.00', currency: 'CNY'),
        totalLiabilities: Money(amount: '0', currency: 'CNY'),
        netWorth: Money(amount: '1000.00', currency: 'CNY'),
      ),
    ),
    if (portfolioRepo != null)
      portfolioRepositoryProvider.overrideWithValue(portfolioRepo)
    else
      valuationIssuesProvider.overrideWith((ref) async => issues),
    if (quoteRepo != null) quoteRepositoryProvider.overrideWithValue(quoteRepo),
  ],
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: OverviewPage()),
        ),
      ],
    ),
  ),
);

void main() {
  group('wire 映射与短状态文案', () {
    test('八种 reason 全部映射为短状态', () {
      const cases = {
        'missing_quote': '暂无报价',
        'stale_quote': '报价较旧',
        'stale_fx': '汇率较旧',
        'offline_cached_quote': '使用缓存报价',
        'offline_cached_fx': '使用缓存汇率',
        'quote_error': '报价获取失败',
        'fx_error': '汇率获取失败',
      };
      cases.forEach((reason, text) {
        final vm = parseValuationIssueData(
          _issueJson(
            id: 'i_$reason',
            assetLabel: 'BTC',
            quantity: '0.5',
            status: 'stale',
            reason: reason,
          ),
        );
        expect(valuationIssueMessage(vm), text, reason: reason);
      });
      final path = parseValuationIssueData(
        _issueJson(
          id: 'i_path',
          assetLabel: 'BTC',
          quantity: '0.5',
          status: 'unpriceable',
          reason: 'missing_fx_path',
        ),
      );
      expect(valuationIssueMessage(path), '缺少 USDT → CNY 的估值路径');
    });

    test('完整字段映射（含可选 asOf 与 cash 类型）', () {
      final vm = parseValuationIssueData(
        _issueJson(
          id: 'valuation_cash_acct_okx_USDT',
          assetLabel: 'USDT',
          quantity: '125.30',
          status: 'offline_cached',
          reason: 'offline_cached_fx',
          assetKind: 'cash',
          asOf: '2026-07-27T03:30:00Z',
        ),
      );
      expect(vm.id, 'valuation_cash_acct_okx_USDT');
      expect(vm.accountId, 'acct_okx');
      expect(vm.assetKind, ValuationAssetKind.cash);
      expect(vm.quantity, '125.30');
      expect(vm.quantityUnit, 'USDT');
      expect(vm.status, ValuationIssueStatus.offlineCached);
      expect(vm.reason, ValuationIssueReason.offlineCachedFx);
      expect(vm.asOf, '2026-07-27T03:30:00Z');

      final noAsOf = parseValuationIssueData(
        _issueJson(
          id: 'i_no_asof',
          assetLabel: 'BTC',
          quantity: '0.5',
          status: 'unpriceable',
          reason: 'missing_quote',
        ),
      );
      expect(noAsOf.asOf, isNull);
    });
  });

  group('首页入口', () {
    testWidgets('无估值问题：入口隐藏、无大待处理卡', (tester) async {
      await tester.pumpWidget(_host(overview: _overview()));
      await tester.pumpAndSettle();
      expect(find.textContaining('估值待完善'), findsNothing);
      expect(find.textContaining('待处理'), findsNothing);
      expect(find.textContaining('报价过期'), findsNothing);
      expect(find.textContaining('本地缓存'), findsNothing);
    });

    testWidgets('只有估值问题：不出大卡，只有低强调入口', (tester) async {
      await tester.pumpWidget(_host(overview: _overview(unpriceable: 3)));
      await tester.pumpAndSettle();
      expect(find.text('估值待完善 3'), findsOneWidget);
      expect(find.textContaining('待处理'), findsNothing);
      expect(find.text('报价问题'), findsNothing);
      expect(find.textContaining('unpriceable'), findsNothing);
      expect(find.textContaining('本地缓存'), findsNothing);
    });

    testWidgets('估值问题与其他待办并存：大卡不含报价问题行', (tester) async {
      await tester.pumpWidget(
        _host(overview: _overview(stale: 2, aiPending: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('待处理'), findsOneWidget);
      expect(find.text('AI 待确认'), findsOneWidget);
      expect(find.text('报价问题'), findsNothing);
      expect(find.text('估值待完善 2'), findsOneWidget);
    });
  });

  group('面板只消费服务端问题列表', () {
    testWidgets('多跳 FX 可用：服务端不返回该资产，前端不得显示缺少路径', (tester) async {
      // USDT 有 USDT/USD + USD/CNY 两段 fresh：接口只报缺报价的 ETH。
      await tester.pumpWidget(
        _host(
          overview: _overview(unpriceable: 1),
          issues: [
            _issue(
              assetLabel: 'ETH',
              quantity: '0.25',
              status: ValuationIssueStatus.unpriceable,
              reason: ValuationIssueReason.missingQuote,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('估值待完善 1'));
      await tester.pumpAndSettle();
      expect(find.text('部分资产暂未计入总值'), findsOneWidget);
      expect(find.textContaining('OKX · ETH 0.25'), findsOneWidget);
      expect(find.text('暂无报价'), findsOneWidget);
      expect(find.textContaining('缺少 USDT → CNY'), findsNothing);
      expect(find.textContaining('USDT'), findsNothing);
    });

    testWidgets('缺 BTC 报价报「暂无报价」；缺 USDT→CNY 路径才报路径', (tester) async {
      await tester.pumpWidget(
        _host(
          overview: _overview(unpriceable: 2),
          issues: [
            _issue(
              assetLabel: 'BTC',
              quantity: '0.00076078',
              status: ValuationIssueStatus.unpriceable,
              reason: ValuationIssueReason.missingQuote,
            ),
            _issue(
              assetLabel: 'ETH',
              quantity: '0.25',
              status: ValuationIssueStatus.unpriceable,
              reason: ValuationIssueReason.missingFxPath,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('估值待完善 2'));
      await tester.pumpAndSettle();
      expect(find.textContaining('OKX · BTC 0.00076078'), findsOneWidget);
      expect(find.text('暂无报价'), findsOneWidget);
      expect(find.textContaining('OKX · ETH 0.25'), findsOneWidget);
      expect(find.text('缺少 USDT → CNY 的估值路径'), findsOneWidget);
    });

    testWidgets('外币现金 stale FX：显示「汇率较旧」并保留原始数量', (tester) async {
      await tester.pumpWidget(
        _host(
          overview: _overview(stale: 1),
          issues: const [
            ValuationIssueVm(
              id: 'valuation_cash_acct_usd_USD',
              accountId: 'acct_usd',
              accountName: '美元账户',
              assetKind: ValuationAssetKind.cash,
              assetId: 'USD',
              assetLabel: 'USD',
              quantity: '10.00',
              quantityUnit: 'USD',
              status: ValuationIssueStatus.stale,
              reason: ValuationIssueReason.staleFx,
              sourceCurrency: 'USD',
              targetCurrency: 'CNY',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('估值待完善 1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('美元账户 · USD 10.00'), findsOneWidget);
      expect(find.text('汇率较旧'), findsOneWidget);
      expect(find.textContaining('缺少'), findsNothing);
    });

    testWidgets('列表加载失败：入口仍在，面板给短错误并可重试成功', (tester) async {
      final repo = _CountingPortfolioRepo([
        null,
        [
          _issue(
            assetLabel: 'ETH',
            quantity: '0.25',
            status: ValuationIssueStatus.unpriceable,
            reason: ValuationIssueReason.missingQuote,
          ),
        ],
      ]);
      await tester.pumpWidget(
        _host(overview: _overview(unpriceable: 1), portfolioRepo: repo),
      );
      await tester.pumpAndSettle();
      // 入口来自 overview，不随问题列表加载失败而消失。
      expect(find.text('估值待完善 1'), findsOneWidget);
      await tester.tap(find.text('估值待完善 1'));
      await tester.pumpAndSettle();
      expect(repo.calls, 1);
      expect(find.text('状态加载失败，请重试。'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      // 失败时不回退到客户端猜测。
      expect(find.textContaining('缺少'), findsNothing);
      expect(find.textContaining('暂无报价'), findsNothing);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(repo.calls, 2);
      expect(find.textContaining('OKX · ETH 0.25'), findsOneWidget);
      expect(find.text('暂无报价'), findsOneWidget);
    });

    testWidgets('刷新失败：面板不关闭并提示', (tester) async {
      final repo = _FakeQuoteRepo(failRefresh: true);
      await tester.pumpWidget(
        _host(
          overview: _overview(unpriceable: 1),
          quoteRepo: repo,
          issues: [
            _issue(
              assetLabel: 'ETH',
              quantity: '0.25',
              status: ValuationIssueStatus.unpriceable,
              reason: ValuationIssueReason.missingQuote,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('估值待完善 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('刷新估值'));
      await tester.pumpAndSettle();
      expect(repo.refreshCalls, 1);
      expect(find.text('部分资产暂未计入总值'), findsOneWidget);
      expect(find.textContaining('刷新失败'), findsOneWidget);
    });
  });
}
