// 首页估值状态降级（2026-07-18 任务单 §2/§3/§5）：
// 大待处理卡不再包含报价问题；净资产旁只留低强调入口且无问题时隐藏；
// 面板列原始数量、区分缺失/较旧/缓存；刷新失败不关闭面板。
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/overview_page.dart';
import 'package:finwealth/features/valuation_status_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _okx = AccountVm(
  id: 'a_okx',
  displayName: 'OKX',
  accountType: AccountType.exchange,
  isLiability: false,
  balanceMode: 'mixed',
  defaultCurrency: 'USDT',
  supportedCurrencies: ['USDT', 'BTC', 'ETH'],
  cashBalances: {'USDT': '125.30'},
);

const _cnyBank = AccountVm(
  id: 'a_bank',
  displayName: '招行储蓄卡',
  accountType: AccountType.bank,
  isLiability: false,
  defaultCurrency: 'CNY',
  cashBalances: {'CNY': '1000.00'},
);

HoldingVm _holding(
  String id,
  String symbol,
  String qty,
  QuoteStatus status, {
  bool priced = false,
}) => HoldingVm(
  id: id,
  accountId: 'a_okx',
  instrumentId: 'inst_$id',
  symbol: symbol,
  displayName: symbol,
  quantity: qty,
  quoteStatus: status,
  marketValue: priced
      ? const ValuedMoney(
          amount: '100.00',
          currency: 'CNY',
          asOf: '2026-07-18T00:00:00Z',
          quality: ValueQuality.exact,
        )
      : null,
);

PortfolioOverviewVm _overview({
  int stale = 0,
  int unpriceable = 0,
  int aiPending = 0,
}) => PortfolioOverviewVm(
  latestSnapshot: NetWorthSnapshotVm(
    id: 'snap_1',
    snapshotAt: '2026-07-18T00:00:00Z',
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
  Future<List<FxRateVm>> listFxRates() async => const [];
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

Widget _host({
  required PortfolioOverviewVm overview,
  List<AccountVm> accounts = const [_okx, _cnyBank],
  List<HoldingVm> holdings = const [],
  List<FxRateVm> fxRates = const [],
  QuoteRepository? quoteRepo,
}) => ProviderScope(
  overrides: [
    overviewProvider.overrideWith((ref) async => overview),
    accountsProvider.overrideWith((ref) async => accounts),
    holdingsProvider.overrideWith((ref) async => holdings),
    fxRatesProvider.overrideWith((ref) async => fxRates),
    allocationProvider.overrideWith(
      (ref) async => const AssetAllocationVm(
        slices: [],
        totalAssets: Money(amount: '1000.00', currency: 'CNY'),
        totalLiabilities: Money(amount: '0', currency: 'CNY'),
        netWorth: Money(amount: '1000.00', currency: 'CNY'),
      ),
    ),
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
  group('composeValuationIssues 纯函数', () {
    test('纯 CNY 账户无任何问题', () {
      expect(
        composeValuationIssues(
          accounts: const [_cnyBank],
          holdings: const [],
          fxRates: const [],
        ),
        isEmpty,
      );
    });

    test('外币余额无汇率 → 缺少估值路径并保留原始数量', () {
      const btcAccount = AccountVm(
        id: 'a_okx',
        displayName: 'OKX',
        accountType: AccountType.exchange,
        isLiability: false,
        cashBalances: {'USDT': '125.30', 'BTC': '0.00076078'},
      );
      final issues = composeValuationIssues(
        accounts: const [btcAccount],
        holdings: const [],
        fxRates: const [],
      );
      expect(issues, hasLength(2));
      final btc = issues.firstWhere((i) => i.assetLabel == 'BTC');
      expect(btc.accountName, 'OKX');
      expect(btc.quantity, '0.00076078');
      expect(btc.message, '缺少 BTC → CNY 的估值路径');
    });

    test('stale FX → 「汇率较旧」而不是缺失；offline cached 才提缓存', () {
      const usdAccount = AccountVm(
        id: 'a_usd',
        displayName: '美元账户',
        accountType: AccountType.bank,
        isLiability: false,
        cashBalances: {'USD': '10.00'},
      );
      FxRateVm rate(QuoteStatus status) => FxRateVm(
        baseCurrency: 'USD',
        quoteCurrency: 'CNY',
        rate: '7.16',
        asOf: '2026-07-01T00:00:00Z',
        status: status,
      );
      expect(
        composeValuationIssues(
          accounts: const [usdAccount],
          holdings: const [],
          fxRates: [rate(QuoteStatus.stale)],
        ).single.message,
        '汇率较旧',
      );
      expect(
        composeValuationIssues(
          accounts: const [usdAccount],
          holdings: const [],
          fxRates: [rate(QuoteStatus.offlineCached)],
        ).single.message,
        '使用缓存汇率',
      );
      expect(
        composeValuationIssues(
          accounts: const [usdAccount],
          holdings: const [],
          fxRates: [rate(QuoteStatus.fresh)],
        ),
        isEmpty,
      );
    });

    test('OKX 多资产：缺 ETH 报价只报 ETH，BTC/USDT 不受影响', () {
      final issues = composeValuationIssues(
        accounts: const [_okx],
        holdings: [
          _holding('btc', 'BTC', '0.00076078', QuoteStatus.fresh, priced: true),
          _holding('eth', 'ETH', '0.42', QuoteStatus.unpriceable),
        ],
        fxRates: const [
          FxRateVm(
            baseCurrency: 'USDT',
            quoteCurrency: 'CNY',
            rate: '7.10',
            asOf: '2026-07-18T00:00:00Z',
            status: QuoteStatus.fresh,
          ),
        ],
      );
      expect(issues, hasLength(1));
      expect(issues.single.assetLabel, 'ETH');
      expect(issues.single.quantity, '0.42');
      expect(issues.single.message, '缺少 ETH → CNY 的估值路径');
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
      // 技术判断不常驻。
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

    testWidgets('点击入口：面板列出原始数量与缺失路径', (tester) async {
      await tester.pumpWidget(
        _host(
          overview: _overview(unpriceable: 1),
          holdings: [_holding('eth', 'ETH', '0.42', QuoteStatus.unpriceable)],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('估值待完善 1'));
      await tester.pumpAndSettle();
      expect(find.text('部分资产暂未计入总值'), findsOneWidget);
      expect(find.textContaining('OKX · ETH 0.42'), findsOneWidget);
      expect(find.text('缺少 ETH → CNY 的估值路径'), findsOneWidget);
      // USDT 余额无汇率也在列。
      expect(find.textContaining('OKX · USDT 125.30'), findsOneWidget);
    });

    testWidgets('刷新失败：面板不关闭并提示', (tester) async {
      final repo = _FakeQuoteRepo(failRefresh: true);
      await tester.pumpWidget(
        _host(overview: _overview(unpriceable: 1), quoteRepo: repo),
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
