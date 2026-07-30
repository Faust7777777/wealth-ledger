// OKX 多资产持仓修正（2026-07-29 修正单 §必测 1-6）：
// 账户合计只用 accountMarketValue（账户折算单位），不与本位币 CNY 混算；
// 全部不可计价时合计为 —；部分可计价显示部分合计与低强调入口；
// 报价刷新的服务端英文不得出现在主界面与 Snackbar；
// 快照确认时账户详情保持挂载并原地刷新；360 宽各态无 overflow。
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/account_detail_page.dart';
import 'package:finwealth/features/account_form_page.dart';
import 'package:finwealth/features/account_holdings_section.dart';
import 'package:finwealth/features/ai_review_page.dart';
import 'package:finwealth/features/holding_snapshot_card.dart';
import 'package:finwealth/features/quote_refresh_messages.dart';
import 'package:finwealth/features/valuation_status_sheet.dart';
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

/// 生产形态：交易所账户折算单位是 USDT，账本本位币是 CNY。
const _okx = AccountVm(
  id: 'a_okx',
  displayName: 'OKX',
  accountType: AccountType.exchange,
  isLiability: false,
  balanceMode: 'mixed',
  defaultCurrency: 'USDT',
  supportedCurrencies: ['USDT', 'BTC', 'ETH'],
);

ValuedMoney _valued(String amount, String currency) => ValuedMoney(
  amount: amount,
  currency: currency,
  asOf: '2026-07-29T09:00:00+08:00',
  quality: ValueQuality.exact,
);

const _instruments = [
  InstrumentVm(
    id: 'inst_btc',
    type: InstrumentType.crypto,
    symbol: 'BTC',
    displayName: 'Bitcoin',
    quoteCurrency: 'USDT',
  ),
  InstrumentVm(
    id: 'inst_eth',
    type: InstrumentType.crypto,
    symbol: 'ETH',
    displayName: 'Ethereum',
    quoteCurrency: 'USDT',
  ),
];

HoldingVm _holding({
  required String id,
  required String instrumentId,
  required String symbol,
  required String name,
  required String quantity,
  ValuedMoney? marketValue,
  ValuedMoney? accountMarketValue,
  QuoteStatus status = QuoteStatus.fresh,
}) => HoldingVm(
  id: id,
  accountId: 'a_okx',
  instrumentId: instrumentId,
  symbol: symbol,
  displayName: name,
  quantity: quantity,
  quoteStatus: status,
  marketValue: marketValue,
  accountMarketValue: accountMarketValue,
);

class _AccountRepo implements AccountRepository {
  const _AccountRepo();
  @override
  Future<AccountVm?> getAccount(Id id) async => _okx;
  @override
  Future<List<AccountVm>> listAccounts() async => const [_okx];
  @override
  Future<List<AccountAnomalyVm>> listAnomalies() async => const [];
  @override
  Future<AccountVm> createAccount(CreateAccountInput input) =>
      throw UnsupportedError('unused');
  @override
  Future<AccountVm> updateAccount(Id id, CreateAccountInput input) =>
      throw UnsupportedError('unused');
  @override
  Future<void> archiveAccount(Id id) => throw UnsupportedError('unused');
}

/// 持仓数量随「确认」推进：模拟服务端在整组确认后才改数量。
class _PortfolioRepo implements PortfolioRepository {
  _PortfolioRepo(this.holdings);
  List<HoldingVm> holdings;
  int accountHoldingReads = 0;

  @override
  Future<List<HoldingVm>> listHoldingsByAccount(Id accountId) async {
    accountHoldingReads += 1;
    return holdings;
  }

  @override
  Future<List<HoldingVm>> listHoldings() async => holdings;
  @override
  Future<PortfolioOverviewVm> getOverview() async => const PortfolioOverviewVm(
    pendingSummary: PendingSummaryVm(),
    quoteStatusSummary: QuoteStatusSummaryVm(),
    primaryHoldings: [],
    recentMovements: [],
  );
  @override
  Future<AssetAllocationVm> getAssetAllocation() async =>
      const AssetAllocationVm(
        slices: [],
        totalAssets: Money(amount: '0', currency: 'CNY'),
        totalLiabilities: Money(amount: '0', currency: 'CNY'),
        netWorth: Money(amount: '0', currency: 'CNY'),
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _snapshotMovement(
  String id,
  String instrumentId,
  String previous,
  String target,
) => {
  'id': id,
  'atomicGroupId': 'ag_snapshot_1',
  'type': 'adjustment',
  'status': 'pending_review',
  'title': '调整持仓',
  'occurredAt': '2026-07-29T10:00:00Z',
  'entries': [
    {
      'id': 'entry_$id',
      'accountId': 'a_okx',
      'instrumentId': instrumentId,
      'amount': '1',
      'currency': 'USDT',
      'direction': 'in',
      'role': 'adjustment',
    },
  ],
  'holdingAdjustment': {
    'accountId': 'a_okx',
    'instrumentId': instrumentId,
    'previousQuantity': previous,
    'targetQuantity': target,
  },
  'tags': ['holding_adjustment', 'holding_snapshot'],
};

AiProposalVm _snapshotProposal() => parseAiProposalData({
  'id': 'ap_1',
  'status': 'pending',
  'summary': 'OKX 持仓快照',
  'source': {'kind': 'manual'},
  'atomicGroups': [
    {
      'id': 'ag_snapshot_1',
      'title': '更新 OKX 持仓',
      'operation': 'modify',
      'status': 'pending',
      'proposedMovements': [
        _snapshotMovement('mv_btc', 'inst_btc', '0.25', '0.4'),
      ],
    },
  ],
});

/// 确认后把持仓改成目标数量，用来验证账户详情原地刷新。
class _ApproveRepo implements AiProposalRepository {
  _ApproveRepo(this.portfolio);
  final _PortfolioRepo portfolio;
  bool cleared = false;
  final List<String> approved = [];

  @override
  Future<List<AiProposalVm>> listPending() async =>
      cleared ? const [] : [_snapshotProposal()];

  @override
  Future<ConfirmResultVm> approveAtomicGroup(Id groupId) async {
    approved.add(groupId);
    cleared = true;
    portfolio.holdings = [
      _holding(
        id: 'h_btc',
        instrumentId: 'inst_btc',
        symbol: 'BTC',
        name: 'Bitcoin',
        quantity: '0.4',
        accountMarketValue: _valued('40000', 'USDT'),
      ),
    ];
    return const ConfirmResultVm(
      atomicGroupId: 'ag_snapshot_1',
      confirmedMovementIds: ['mv_btc'],
      snapshotInvalidated: true,
      ledgerWrite: true,
    );
  }

  @override
  Future<void> rejectAtomicGroup(Id groupId, {String? reason}) async {
    cleared = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QuoteRepo implements QuoteRepository {
  _QuoteRepo(this.result, {this.throws = false});
  final QuoteRefreshResultVm result;
  final bool throws;
  @override
  Future<QuoteRefreshResultVm> refreshQuotes({required String mode}) async {
    if (throws) throw Exception('instrument has no public-provider symbol');
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _detailHost(_PortfolioRepo portfolio) => ProviderScope(
  overrides: [
    capabilitiesProvider.overrideWith((ref) async => _caps),
    accountRepositoryProvider.overrideWithValue(const _AccountRepo()),
    portfolioRepositoryProvider.overrideWithValue(portfolio),
    instrumentsProvider.overrideWith((ref) async => _instruments),
    aiPendingProvider.overrideWith((ref) async => const <AiProposalVm>[]),
    fxRatesProvider.overrideWith((ref) async => const <FxRateVm>[]),
  ],
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const AccountDetailPage(accountId: 'a_okx'),
        ),
      ],
    ),
  ),
);

/// 账户详情与审核页同屏：验证确认后详情原地刷新，不依赖退出重进。
Widget _detailAndReviewHost(_PortfolioRepo portfolio, _ApproveRepo aiRepo) =>
    ProviderScope(
      overrides: [
        capabilitiesProvider.overrideWith((ref) async => _caps),
        accountRepositoryProvider.overrideWithValue(const _AccountRepo()),
        portfolioRepositoryProvider.overrideWithValue(portfolio),
        aiProposalRepositoryProvider.overrideWithValue(aiRepo),
        instrumentsProvider.overrideWith((ref) async => _instruments),
        accountsProvider.overrideWith((ref) async => const [_okx]),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const Column(
                children: [
                  SizedBox(
                    height: 320,
                    child: AccountDetailPage(accountId: 'a_okx'),
                  ),
                  Expanded(child: AiReviewPage()),
                ],
              ),
            ),
            GoRoute(
              path: '/ai-edit/:id',
              builder: (_, _) => const Placeholder(),
            ),
          ],
        ),
      ),
    );

Widget _shellHost(_QuoteRepo quoteRepo) => ProviderScope(
  overrides: [
    capabilitiesProvider.overrideWith((ref) async => _caps),
    quoteRepositoryProvider.overrideWithValue(quoteRepo),
    accountsProvider.overrideWith((ref) async => const [_okx]),
    holdingsProvider.overrideWith((ref) async => const <HoldingVm>[]),
    overviewProvider.overrideWith(
      (ref) async => const PortfolioOverviewVm(
        pendingSummary: PendingSummaryVm(),
        quoteStatusSummary: QuoteStatusSummaryVm(),
        primaryHoldings: [],
        recentMovements: [],
      ),
    ),
    allocationProvider.overrideWith(
      (ref) async => const AssetAllocationVm(
        slices: [],
        totalAssets: Money(amount: '0', currency: 'CNY'),
        totalLiabilities: Money(amount: '0', currency: 'CNY'),
        netWorth: Money(amount: '0', currency: 'CNY'),
      ),
    ),
    fxRatesProvider.overrideWith((ref) async => const <FxRateVm>[]),
    aiPendingProvider.overrideWith((ref) async => const <AiProposalVm>[]),
  ],
  child: const MaterialApp(home: Scaffold(body: ValuationStatusDialog())),
);

/// 全部可见文本（含 SelectableText）拼成一段，用于英文泄漏扫描。
String _visibleText(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? '',
  for (final t in tester.widgetList<SelectableText>(
    find.byType(SelectableText),
  ))
    t.data ?? '',
].join('\n');

void main() {
  group('P0.1 账户合计币种', () {
    test('只累加 accountMarketValue，不碰本位币 marketValue', () {
      final holdings = [
        _holding(
          id: 'h_btc',
          instrumentId: 'inst_btc',
          symbol: 'BTC',
          name: 'Bitcoin',
          quantity: '0.25',
          marketValue: _valued('120000', 'CNY'),
          accountMarketValue: _valued('16800', 'USDT'),
        ),
        _holding(
          id: 'h_eth',
          instrumentId: 'inst_eth',
          symbol: 'ETH',
          name: 'Ethereum',
          quantity: '3.2',
          marketValue: _valued('80000', 'CNY'),
          accountMarketValue: _valued('11200', 'USDT'),
        ),
      ];
      final total = accountHoldingsTotal(_okx, holdings);
      expect(total.currency, 'USDT');
      expect(total.amount, '28000');
      expect(total.pricedCount, 2);
      expect(total.missingCount, 0);
      expect(total.hasAmount, isTrue);
    });

    testWidgets('账户详情只显示 USDT 合计，不出现 CNY 合计', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final portfolio = _PortfolioRepo([
        _holding(
          id: 'h_btc',
          instrumentId: 'inst_btc',
          symbol: 'BTC',
          name: 'Bitcoin',
          quantity: '0.25',
          marketValue: _valued('120000', 'CNY'),
          accountMarketValue: _valued('16800', 'USDT'),
        ),
      ]);
      await tester.pumpWidget(_detailHost(portfolio));
      await tester.pumpAndSettle();

      expect(find.text('合计（USDT）'), findsOneWidget);
      expect(find.textContaining('16,800'), findsWidgets);
      // 本位币金额不出现在账户合计里。
      expect(find.textContaining('120,000'), findsNothing);
    });

    test('全部不可计价：合计为 — 而不是 0', () {
      final holdings = [
        _holding(
          id: 'h_btc',
          instrumentId: 'inst_btc',
          symbol: 'BTC',
          name: 'Bitcoin',
          quantity: '0.25',
          marketValue: _valued('120000', 'CNY'),
          status: QuoteStatus.unpriceable,
        ),
        _holding(
          id: 'h_eth',
          instrumentId: 'inst_eth',
          symbol: 'ETH',
          name: 'Ethereum',
          quantity: '3.2',
          status: QuoteStatus.error,
        ),
      ];
      final total = accountHoldingsTotal(_okx, holdings);
      expect(total.pricedCount, 0);
      expect(total.hasAmount, isFalse);
      expect(total.missingQuoteCount, 2);
      expect(total.excludedLabel, '2 项待补报价');
    });

    testWidgets('全部不可计价时界面显示 —，且没有 0 合计', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final portfolio = _PortfolioRepo([
        _holding(
          id: 'h_btc',
          instrumentId: 'inst_btc',
          symbol: 'BTC',
          name: 'Bitcoin',
          quantity: '0.25',
          marketValue: _valued('120000', 'CNY'),
        ),
        _holding(
          id: 'h_eth',
          instrumentId: 'inst_eth',
          symbol: 'ETH',
          name: 'Ethereum',
          quantity: '3.2',
        ),
      ]);
      await tester.pumpWidget(_detailHost(portfolio));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(find.text('合计（USDT）'), findsOneWidget);
      expect(find.text('—'), findsWidgets);
      expect(find.text('USDT 0.00'), findsNothing);
      expect(find.text('0.00'), findsNothing);
      // 数量仍然完整可见。
      expect(find.text('0.25'), findsOneWidget);
      expect(find.text('3.2'), findsOneWidget);
      expect(find.byKey(kAccountMissingQuotesKey), findsOneWidget);
    });

    testWidgets('一项可计价、一项缺报价：部分合计 + 1 项入口', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final portfolio = _PortfolioRepo([
        _holding(
          id: 'h_btc',
          instrumentId: 'inst_btc',
          symbol: 'BTC',
          name: 'Bitcoin',
          quantity: '0.25',
          accountMarketValue: _valued('16800', 'USDT'),
        ),
        _holding(
          id: 'h_eth',
          instrumentId: 'inst_eth',
          symbol: 'ETH',
          name: 'Ethereum',
          quantity: '3.2',
          status: QuoteStatus.unpriceable,
        ),
      ]);
      await tester.pumpWidget(_detailHost(portfolio));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('16,800'), findsWidgets);
      expect(find.text('1 项待补报价'), findsOneWidget);
    });
  });

  group('P0.2 报价错误文案', () {
    test('结构化失败 → 短中文，目标币种取接口值', () {
      expect(
        quoteRefreshErrorText(
          const QuoteRefreshErrorVm(
            targetType: 'instrument',
            targetId: 'inst_btc',
            message: 'instrument has no public-provider symbol',
            retryable: false,
          ),
        ),
        '无法识别该资产',
      );
      expect(
        quoteRefreshErrorText(
          const QuoteRefreshErrorVm(
            targetType: 'instrument',
            targetId: 'inst_btc',
            message: 'quote provider returned no price',
          ),
        ),
        '暂时没有可用报价',
      );
      expect(
        quoteRefreshErrorText(
          const QuoteRefreshErrorVm(
            targetType: 'fx_pair',
            targetId: 'BTC/CNY',
            message: 'FX pair has no Yahoo symbol',
          ),
        ),
        '暂时无法换算为 CNY',
      );
      // 目标币种不硬编码：换成 USDT 就跟着变。
      expect(
        quoteRefreshErrorText(
          const QuoteRefreshErrorVm(
            targetType: 'fx_pair',
            targetId: 'ETH/USDT',
            message: 'FX pair has no Yahoo symbol',
          ),
        ),
        '暂时无法换算为 USDT',
      );
      expect(
        quoteRefreshErrorText(
          const QuoteRefreshErrorVm(
            targetType: 'request',
            message: 'upstream 502',
          ),
        ),
        '刷新失败，请重试',
      );
    });

    test('整次结果文案不含服务端英文', () {
      final text = quoteRefreshResultText(
        const QuoteRefreshResultVm(
          status: 'partial_success',
          completedAt: '2026-07-29T10:00:00Z',
          quoteCount: 1,
          fxRateCount: 2,
          errors: ['instrument has no public-provider symbol'],
          errorDetails: [
            QuoteRefreshErrorVm(
              targetType: 'instrument',
              targetId: 'inst_btc',
              message: 'instrument has no public-provider symbol',
            ),
          ],
        ),
      );
      expect(text, '部分报价未刷新，继续使用缓存：无法识别该资产');
      expect(text.contains('public-provider'), isFalse);
    });

    test('wire → VM 保留结构化字段', () {
      final result = parseQuoteRefreshResultData(const {
        'status': 'partial_success',
        'completedAt': '2026-07-29T10:00:00Z',
        'quotes': [],
        'fxRates': [],
        'errors': [
          {
            'targetType': 'instrument',
            'targetId': 'inst_btc',
            'message': 'instrument has no public-provider symbol',
            'retryable': false,
          },
        ],
      });
      expect(result.errorDetails.single.targetType, 'instrument');
      expect(result.errorDetails.single.retryable, isFalse);
      expect(quoteRefreshErrorText(result.errorDetails.single), '无法识别该资产');
    });

    testWidgets('估值面板刷新失败：界面与 Snackbar 都没有英文实现细节', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _shellHost(
          _QuoteRepo(
            const QuoteRefreshResultVm(
              status: 'partial_success',
              completedAt: '2026-07-29T10:00:00Z',
              errors: ['instrument has no public-provider symbol'],
              errorDetails: [
                QuoteRefreshErrorVm(
                  targetType: 'instrument',
                  targetId: 'inst_btc',
                  message: 'instrument has no public-provider symbol',
                ),
                QuoteRefreshErrorVm(
                  targetType: 'fx_pair',
                  targetId: 'BTC/CNY',
                  message: 'FX pair has no Yahoo symbol',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('刷新估值'));
      await tester.pumpAndSettle();

      final visible = _visibleText(tester);
      expect(visible.contains('public-provider'), isFalse);
      expect(visible.contains('Yahoo'), isFalse);
      expect(visible.contains('instrument has no'), isFalse);
      expect(find.textContaining('无法识别该资产'), findsWidgets);
      expect(tester.takeException(), isNull);

      // 服务端原文只在低强调详情里出现。
      expect(find.byKey(kValuationErrorDetailsKey), findsOneWidget);
      await tester.tap(find.byKey(kValuationErrorDetailsKey));
      await tester.pumpAndSettle();
      expect(find.textContaining('public-provider'), findsOneWidget);
      expect(find.textContaining('暂时无法换算为 CNY'), findsWidgets);
    });

    testWidgets('刷新抛异常：Snackbar 不拼接异常原文', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _shellHost(
          _QuoteRepo(
            const QuoteRefreshResultVm(
              status: 'failed',
              completedAt: '2026-07-29T10:00:00Z',
            ),
            throws: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('刷新估值'));
      await tester.pumpAndSettle();
      expect(find.text(kQuoteRefreshFailureText), findsOneWidget);
      expect(_visibleText(tester).contains('public-provider'), isFalse);
    });
  });

  group('P0.3 审核后精确刷新账户详情', () {
    test('从组内推导涉及账户：holdingAdjustment 优先，退回 entry', () {
      final group = _snapshotProposal().groups.single;
      expect(holdingGroupAccountIds(group), {'a_okx'});

      final entryOnly = parseAiProposalData({
        'id': 'ap_2',
        'status': 'pending',
        'source': {'kind': 'manual'},
        'atomicGroups': [
          {
            'id': 'ag_2',
            'title': '调整',
            'operation': 'modify',
            'status': 'pending',
            'proposedMovements': [
              {
                'id': 'mv_1',
                'atomicGroupId': 'ag_2',
                'type': 'adjustment',
                'status': 'pending_review',
                'title': '调整',
                'occurredAt': '2026-07-29T10:00:00Z',
                'entries': [
                  {
                    'id': 'e1',
                    'accountId': 'a_other',
                    'amount': '1',
                    'currency': 'USDT',
                    'direction': 'in',
                    'role': 'adjustment',
                  },
                ],
                'tags': ['holding_adjustment'],
              },
            ],
          },
        ],
      }).groups.single;
      expect(holdingGroupAccountIds(entryOnly), {'a_other'});
    });

    testWidgets('账户详情保持挂载：确认后数量原地更新', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final portfolio = _PortfolioRepo([
        _holding(
          id: 'h_btc',
          instrumentId: 'inst_btc',
          symbol: 'BTC',
          name: 'Bitcoin',
          quantity: '0.25',
          accountMarketValue: _valued('16800', 'USDT'),
        ),
      ]);
      final aiRepo = _ApproveRepo(portfolio);
      await tester.pumpWidget(_detailAndReviewHost(portfolio, aiRepo));
      await tester.pumpAndSettle();

      expect(find.text('0.25'), findsOneWidget);
      final readsBefore = portfolio.accountHoldingReads;

      await tester.tap(find.text('接受整组'));
      await tester.pumpAndSettle();

      expect(aiRepo.approved, ['ag_snapshot_1']);
      expect(
        portfolio.accountHoldingReads,
        greaterThan(readsBefore),
        reason: '必须精确失效 holdingsByAccountProvider',
      );
      // 详情从未卸载，数量原地变成 0.4。
      expect(find.byType(AccountDetailPage), findsOneWidget);
      expect(find.text('0.4'), findsOneWidget);
      expect(find.text('0.25'), findsNothing);
    });
  });

  group('P0.4 账户表单术语与默认值', () {
    test('交易所与钱包默认折算单位是 USDT，其余是 CNY', () {
      expect(defaultConversionUnitFor(AccountType.exchange), 'USDT');
      expect(defaultConversionUnitFor(AccountType.wallet), 'USDT');
      expect(defaultConversionUnitFor(AccountType.bank), 'CNY');
      expect(defaultConversionUnitFor(AccountType.brokerage), 'CNY');
    });

    testWidgets('新建交易所账户：折算单位默认 USDT，术语已更新', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [capabilitiesProvider.overrideWith((ref) async => _caps)],
          child: const MaterialApp(
            home: AccountFormPage(initialType: AccountType.exchange),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('账户折算单位'), findsOneWidget);
      expect(find.text('交易计价单位'), findsOneWidget);
      // 旧术语不再出现。
      expect(find.text('默认币种'), findsNothing);
      expect(find.text('支持币种'), findsNothing);
      expect(find.text('USDT'), findsWidgets);
      expect(tester.takeException(), isNull);

      // 说明只在帮助入口里，正文没有解释段落。
      expect(find.byKey(kAccountTradingUnitsHelpKey), findsOneWidget);
      expect(find.textContaining('持有哪些资产'), findsNothing);
      await tester.tap(find.byKey(kAccountTradingUnitsHelpKey));
      await tester.pumpAndSettle();
      expect(find.textContaining('持有哪些资产'), findsOneWidget);
    });

    testWidgets('编辑既有账户：不静默改折算单位', (tester) async {
      const existing = AccountVm(
        id: 'a_bank',
        displayName: '招行',
        accountType: AccountType.bank,
        isLiability: false,
        defaultCurrency: 'CNY',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [capabilitiesProvider.overrideWith((ref) async => _caps)],
          child: const MaterialApp(home: AccountFormPage(existing: existing)),
        ),
      );
      await tester.pumpAndSettle();
      // 打开就是服务端的 CNY，没有被类型默认值覆盖。
      expect(find.text('CNY'), findsWidgets);
      expect(find.text('USDT'), findsNothing);
    });
  });

  group('P0.6 窄屏无 overflow', () {
    testWidgets('360 宽：多资产列表 + 估值弹层 + 错误态', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final portfolio = _PortfolioRepo([
        _holding(
          id: 'h_btc',
          instrumentId: 'inst_btc',
          symbol: 'BTC',
          name: 'Bitcoin',
          quantity: '0.00076078',
          accountMarketValue: _valued('16800.12', 'USDT'),
        ),
        _holding(
          id: 'h_eth',
          instrumentId: 'inst_eth',
          symbol: 'ETH',
          name: 'Ethereum',
          quantity: '3.2',
          status: QuoteStatus.error,
        ),
      ]);
      await tester.pumpWidget(_detailHost(portfolio));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '多资产列表');

      await tester.tap(find.byKey(kAccountMissingQuotesKey));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '估值弹层');
      expect(find.byType(ValuationStatusDialog), findsOneWidget);
    });
  });
}
