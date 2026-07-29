// 多资产账户 + 持仓校准（2026-07-18 任务单 §4 + 用户 P0-4/5）：
// 一个账户多行资产原始数量展示、缺报价显「暂无估值」不显 0；
// 新增/校准走 POST /v1/accounts/{id}/holding-adjustment-proposals；
// 覆盖增加/减少/清零/重复提交/409/币种不支持/窄屏桌面。
import 'dart:convert';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/account_detail_page.dart';
import 'package:finwealth/features/account_form_validation.dart';
import 'package:finwealth/features/holding_adjustment_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _caps = LedgerCapabilitiesVm(
  dataSourceMode: 'local_server',
  canWriteConfirmedLedger: true,
  canCreateAccount: true,
  canRecordMovement: true,
  canConfirmProposal: true,
  canPersistPendingProposal: true,
  proposalPersistence: 'file',
);

const _okx = AccountVm(
  id: 'a_okx',
  displayName: 'OKX',
  accountType: AccountType.exchange,
  isLiability: false,
  balanceMode: 'mixed',
  defaultCurrency: 'USDT',
  supportedCurrencies: ['USDT', 'BTC', 'ETH'],
  cashBalances: {'USDT': '123.45'},
  value: ValuedMoney(
    amount: '890.00',
    currency: 'CNY',
    asOf: '2026-07-18T09:00:00+08:00',
    quality: ValueQuality.incomplete,
  ),
);

const _btc = HoldingVm(
  id: 'h_btc',
  accountId: 'a_okx',
  instrumentId: 'inst_btc',
  symbol: 'BTC',
  displayName: 'Bitcoin',
  quantity: '0.00076078',
  quoteStatus: QuoteStatus.fresh,
  marketValue: ValuedMoney(
    amount: '380.00',
    currency: 'CNY',
    asOf: '2026-07-18T09:00:00+08:00',
    quality: ValueQuality.estimated,
  ),
);

const _eth = HoldingVm(
  id: 'h_eth',
  accountId: 'a_okx',
  instrumentId: 'inst_eth',
  symbol: 'ETH',
  displayName: 'Ethereum',
  quantity: '0.25',
  quoteStatus: QuoteStatus.unpriceable,
);

const _instruments = [
  InstrumentVm(
    id: 'inst_btc',
    type: InstrumentType.crypto,
    symbol: 'BTC',
    displayName: 'Bitcoin',
    quoteCurrency: 'BTC',
  ),
  InstrumentVm(
    id: 'inst_sol',
    type: InstrumentType.crypto,
    symbol: 'SOL',
    displayName: 'Solana',
    quoteCurrency: 'SOL',
  ),
];

/// 捕获真实 HTTP 的 portfolio 仓库（走 MockClient 的 LocalServer 实现）。
({PortfolioRepository repo, List<http.Request> requests}) _portfolioRepo({
  int failStatus = 0,
}) {
  final requests = <http.Request>[];
  final client = DevApiClient(
    'http://127.0.0.1:1',
    client: MockClient((req) async {
      requests.add(req);
      if (failStatus == 409) {
        return http.Response(
          jsonEncode({
            'ok': false,
            'error': {'code': 'holding_conflict', 'message': '数据已变化'},
          }),
          409,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (failStatus == 400) {
        return http.Response(
          jsonEncode({
            'ok': false,
            'error': {
              'code': 'invalid_local_request',
              'message': 'Local ledger request is invalid.',
              'details': {
                'errors': ['account does not support instrument currency'],
              },
            },
          }),
          400,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response(
        jsonEncode({
          'ok': true,
          'data': {
            'id': 'ag_adj_1',
            'title': '持仓校准',
            'operation': 'modify',
            'status': 'pending',
          },
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
  return (repo: LocalServerPortfolioRepository(client), requests: requests);
}

/// 详情页宿主用 fake：读模型固定，写路径转发到捕获仓库。
class _FakePortfolioRepo implements PortfolioRepository {
  _FakePortfolioRepo(this.inner);
  final PortfolioRepository inner;
  final List<HoldingVm> holdings = const [_btc, _eth];

  @override
  Future<List<HoldingVm>> listHoldingsByAccount(Id accountId) async => [
    for (final h in holdings)
      if (h.accountId == accountId) h,
  ];
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
  Future<AiAtomicGroupVm> proposeHoldingAdjustment(
    Id accountId,
    HoldingAdjustmentInput input,
  ) => inner.proposeHoldingAdjustment(accountId, input);
}

class _FakeAccountRepo implements AccountRepository {
  const _FakeAccountRepo();
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

Widget _host(
  PortfolioRepository portfolioRepo, {
  void Function()? onAiPending,
}) => ProviderScope(
  overrides: [
    capabilitiesProvider.overrideWith((ref) async => _caps),
    accountRepositoryProvider.overrideWithValue(const _FakeAccountRepo()),
    portfolioRepositoryProvider.overrideWithValue(portfolioRepo),
    instrumentsProvider.overrideWith((ref) async => _instruments),
    aiPendingProvider.overrideWith((ref) async {
      onAiPending?.call();
      return const <AiProposalVm>[];
    }),
  ],
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(
          path: '/',
          // 隐藏 watcher：让 aiPendingProvider 的 invalidate 触发重算可观测。
          builder: (_, _) => Column(
            children: [
              Consumer(
                builder: (_, ref, _) {
                  ref.watch(aiPendingProvider);
                  return const SizedBox.shrink();
                },
              ),
              const Expanded(child: AccountDetailPage(accountId: 'a_okx')),
            ],
          ),
        ),
        GoRoute(path: '/ai-review', builder: (_, _) => const Placeholder()),
      ],
    ),
  ),
);

Future<void> _pump(
  WidgetTester tester,
  PortfolioRepository repo, {
  void Function()? onAiPending,
  Size size = const Size(900, 1400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_host(repo, onAiPending: onAiPending));
  await tester.pumpAndSettle();
}

void main() {
  group('repository 映射', () {
    test('增加/减少/清零走同一端点，body 逐字段正确 + 幂等键', () async {
      for (final (target, note) in const [
        ('10', '导入现有持仓'),
        ('6', null),
        ('0', null),
      ]) {
        final h = _portfolioRepo();
        final group = await h.repo.proposeHoldingAdjustment(
          'a_okx',
          HoldingAdjustmentInput(
            instrumentId: 'inst_btc',
            targetQuantity: target,
            note: note,
          ),
        );
        expect(group.status, AiGroupStatus.pending);
        final req = h.requests.single;
        expect(req.method, 'POST');
        expect(req.url.path, '/v1/accounts/a_okx/holding-adjustment-proposals');
        expect(
          req.headers['idempotency-key'],
          matches(RegExp(r'^[0-9a-f]{32}$')),
        );
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['instrumentId'], 'inst_btc');
        expect(body['targetQuantity'], target);
        expect(body.containsKey('note'), note != null);
        if (note != null) expect(body['note'], note);
        expect(body.containsKey('asOf'), isFalse);
      }
    });

    test('409/400 抛出对应异常，不伪造成功', () async {
      const input = HoldingAdjustmentInput(
        instrumentId: 'inst_btc',
        targetQuantity: '1',
      );
      await expectLater(
        _portfolioRepo(
          failStatus: 409,
        ).repo.proposeHoldingAdjustment('a_okx', input),
        throwsA(isA<ApiConflictException>()),
      );
      await expectLater(
        _portfolioRepo(
          failStatus: 400,
        ).repo.proposeHoldingAdjustment('a_okx', input),
        throwsA(isA<ApiValidationException>()),
      );
    });
  });

  group('纯校验', () {
    test('目标数量：负数/非法/超 8 位小数拦截；0 与正数通过', () {
      for (final bad in ['', '-1', 'abc', '1.2.3', '0.123456789']) {
        expect(targetQuantityError(bad), isNotNull, reason: bad);
      }
      for (final ok in ['0', '10', '0.00076078']) {
        expect(targetQuantityError(ok), isNull, reason: ok);
      }
    });
  });

  group('多资产展示', () {
    testWidgets('一个账户下多行资产：原始数量全部显示，缺报价显「暂无估值」', (tester) async {
      final h = _portfolioRepo();
      await _pump(tester, _FakePortfolioRepo(h.repo));
      // 现金与稳定币分组 + 原始数量。
      expect(find.text('现金与稳定币'), findsOneWidget);
      expect(find.text('USDT'), findsOneWidget);
      expect(find.text('123.45'), findsOneWidget);
      // 持仓分组：BTC 有估值、ETH 无估值仍显示原始数量。
      expect(find.text('持仓'), findsOneWidget);
      expect(find.text('0.00076078'), findsOneWidget);
      expect(find.text('0.25'), findsOneWidget);
      expect(find.text('暂无估值'), findsOneWidget);
      // 缺报价的资产绝不显示成 0 元。
      expect(find.textContaining('¥0'), findsNothing);
      // 账户总值带质量（≈）与估值时间。
      expect(find.textContaining('截至 2026-07-18'), findsOneWidget);
    });

    testWidgets('360 与 1200 宽无 overflow', (tester) async {
      for (final size in const [Size(360, 800), Size(1200, 800)]) {
        final h = _portfolioRepo();
        await _pump(tester, _FakePortfolioRepo(h.repo), size: size);
        expect(tester.takeException(), isNull, reason: '$size');
      }
    });
  });

  group('校准与新增', () {
    testWidgets('点持仓行 → 校准弹窗（带当前数量）→ 提交减少到 6', (tester) async {
      var aiRuns = 0;
      final h = _portfolioRepo();
      await _pump(
        tester,
        _FakePortfolioRepo(h.repo),
        onAiPending: () => aiRuns += 1,
      );
      await tester.tap(find.text('Bitcoin · BTC'));
      await tester.pumpAndSettle();
      expect(find.text('校准持仓'), findsOneWidget);
      expect(find.textContaining('当前 0.00076078'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '目标数量'), '6');
      await tester.pump();
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      final body = jsonDecode(h.requests.single.body) as Map<String, dynamic>;
      expect(body['instrumentId'], 'inst_btc');
      expect(body['targetQuantity'], '6');
      expect(find.text('已加入待确认'), findsOneWidget);
      expect(find.text('前往审核'), findsOneWidget);
      expect(aiRuns, 2, reason: '成功后 AI 待确认重算');
    });

    testWidgets('清零（0）可提交；负数与超 8 位小数不可提交', (tester) async {
      final h = _portfolioRepo();
      await _pump(tester, _FakePortfolioRepo(h.repo));
      await tester.tap(find.text('Ethereum · ETH'));
      await tester.pumpAndSettle();
      Future<void> enter(String v) async {
        await tester.enterText(find.widgetWithText(TextField, '目标数量'), v);
        await tester.pump();
      }

      FilledButton submit() => tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('提交'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
      );
      await enter('0.123456789');
      expect(submit().onPressed, isNull);
      await enter('0');
      expect(submit().onPressed, isNotNull);
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      final body = jsonDecode(h.requests.single.body) as Map<String, dynamic>;
      expect(body['targetQuantity'], '0');
      expect(body['instrumentId'], 'inst_eth');
    });

    testWidgets('添加资产：从服务端标的选择；不支持的报价币种被拦截', (tester) async {
      final h = _portfolioRepo();
      await _pump(tester, _FakePortfolioRepo(h.repo));
      await tester.tap(find.text('添加资产'));
      await tester.pumpAndSettle();
      // SOL 报价币种不在 OKX supportedCurrencies。
      await tester.tap(find.byKey(kHoldingAdjustmentInstrumentFieldKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Solana · SOL（SOL）').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '目标数量'), '1');
      await tester.pump();
      expect(find.textContaining('不支持此资产的报价币种'), findsOneWidget);
      final blocked = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('提交'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
      );
      expect(blocked.onPressed, isNull);
      // 换成受支持的 BTC 即可提交。
      await tester.tap(find.byKey(kHoldingAdjustmentInstrumentFieldKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bitcoin · BTC（BTC）').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(
        (jsonDecode(h.requests.single.body)
            as Map<String, dynamic>)['instrumentId'],
        'inst_btc',
      );
    });

    testWidgets('重复提交被 busy 拦截（只发一次请求）', (tester) async {
      final h = _portfolioRepo();
      await _pump(tester, _FakePortfolioRepo(h.repo));
      await tester.tap(find.text('Bitcoin · BTC'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '目标数量'), '2');
      await tester.pump();
      await tester.tap(find.text('提交'));
      await tester.pump();
      // 第二次点击发生在请求返回前。
      await tester.tap(find.text('提交'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(h.requests, hasLength(1));
    });

    testWidgets('409：提示数据已变化并给重新加载，不显示成功', (tester) async {
      final h = _portfolioRepo(failStatus: 409);
      await _pump(tester, _FakePortfolioRepo(h.repo));
      await tester.tap(find.text('Bitcoin · BTC'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '目标数量'), '2');
      await tester.pump();
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(find.textContaining('数据已发生变化'), findsOneWidget);
      expect(find.text('重新加载'), findsOneWidget);
      expect(find.text('已加入待确认'), findsNothing);
      // 弹窗保留，输入不丢。
      expect(find.text('校准持仓'), findsOneWidget);
    });

    testWidgets('400（币种不支持等）：显示服务端校验原因', (tester) async {
      final h = _portfolioRepo(failStatus: 400);
      await _pump(tester, _FakePortfolioRepo(h.repo));
      await tester.tap(find.text('Bitcoin · BTC'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '目标数量'), '2');
      await tester.pump();
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('account does not support instrument currency'),
        findsOneWidget,
      );
      expect(find.text('已加入待确认'), findsNothing);
    });
  });
}
