// 手动投资成交：entries 映射（买/卖/费用腿省略/同账户同币种）、幂等重放、
// 校验（数量/金额/费用上限/持仓上限）、标的选择规则、错误与 ledgerWrite 语义、
// saleResult/costBasisFx 映射与展示、旧记录兼容、响应式（2026-07-17 任务单 §11）。
import 'dart:convert';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/auth_store.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/investment_trade_page.dart';
import 'package:finwealth/features/investment_trade_validation.dart';
import 'package:finwealth/features/movement_detail_page.dart';
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

AccountVm _acct(
  String id,
  String name,
  String mode, {
  bool archived = false,
  String currency = 'CNY',
  List<String> supported = const ['CNY'],
}) => AccountVm(
  id: id,
  displayName: name,
  accountType: mode == 'cash_balance'
      ? AccountType.bank
      : AccountType.brokerage,
  isLiability: mode == 'liability',
  balanceMode: mode,
  isArchived: archived,
  defaultCurrency: currency,
  supportedCurrencies: supported,
);

final _accounts = [
  _acct('a_cash', '招行储蓄卡', 'cash_balance'),
  _acct('a_hold', 'A股券商', 'holdings'),
  _acct('a_mixed', '混合老账户', 'mixed'),
  _acct('a_liab', '房贷', 'liability'),
  _acct('a_gone', '已归档券商', 'holdings', archived: true),
];

const _instruments = [
  InstrumentVm(
    id: 'inst_pos',
    type: InstrumentType.fund,
    symbol: '510300',
    displayName: '沪深300ETF',
    quoteCurrency: 'CNY',
  ),
  InstrumentVm(
    id: 'inst_zero',
    type: InstrumentType.fund,
    symbol: '510500',
    displayName: '中证500ETF',
    quoteCurrency: 'CNY',
  ),
  InstrumentVm(
    id: 'inst_other',
    type: InstrumentType.equity,
    symbol: 'NVDA',
    displayName: 'NVIDIA',
    quoteCurrency: 'USD',
  ),
];

const _holdings = [
  HoldingVm(
    id: 'h_pos',
    accountId: 'a_hold',
    instrumentId: 'inst_pos',
    symbol: '510300',
    displayName: '沪深300ETF',
    quantity: '6',
    quoteStatus: QuoteStatus.fresh,
  ),
  HoldingVm(
    id: 'h_zero',
    accountId: 'a_hold',
    instrumentId: 'inst_zero',
    symbol: '510500',
    displayName: '中证500ETF',
    quantity: '0',
    quoteStatus: QuoteStatus.fresh,
  ),
  HoldingVm(
    id: 'h_other',
    accountId: 'a_mixed',
    instrumentId: 'inst_other',
    symbol: 'NVDA',
    displayName: 'NVIDIA',
    quantity: '3',
    quoteStatus: QuoteStatus.fresh,
  ),
];

const _buyInput = InvestmentTradeInput(
  side: TradeSide.buy,
  cashAccountId: 'a_cash',
  holdingAccountId: 'a_hold',
  instrumentId: 'inst_pos',
  quantity: '10',
  principalAmount: '100.00',
  cashCurrency: 'CNY',
  holdingCurrency: 'CNY',
  feeAmount: '2.00',
  taxAmount: '1.00',
  occurredAt: '2026-07-16T10:30:00+08:00',
  title: '买入 沪深300ETF',
);

/// 捕获真实 HTTP 的 movement 仓库（drafts → submit-review → confirm 全流水线）。
({MovementRepository repo, List<http.Request> requests}) _tradeRepo({
  int failStatus = 0,
  bool ledgerWrite = true,
}) {
  final requests = <http.Request>[];
  final client = DevApiClient(
    'http://127.0.0.1:1',
    client: MockClient((req) async {
      requests.add(req);
      if (failStatus != 0) {
        return http.Response(
          jsonEncode({
            'ok': false,
            'error': {'code': 'test_failure', 'message': '服务端拒绝（$failStatus）'},
          }),
          failStatus,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      final data = switch (req.url.path) {
        '/v1/movements/drafts' => {'id': 'mov_1', 'atomicGroupId': 'ag_1'},
        '/v1/atomic-groups/ag_1/confirm' => {
          'atomicGroupId': 'ag_1',
          'confirmedMovementIds': ['mov_1'],
          'snapshotInvalidated': ledgerWrite,
          'ledgerWrite': ledgerWrite,
        },
        _ => <String, Object?>{},
      };
      return http.Response(
        jsonEncode({'ok': true, 'data': data}),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
  return (repo: LocalServerMovementRepository(client), requests: requests);
}

Map<String, dynamic> _draftBody(List<http.Request> requests) =>
    jsonDecode(
          requests.firstWhere((r) => r.url.path == '/v1/movements/drafts').body,
        )
        as Map<String, dynamic>;

class _FakePortfolioRepo implements PortfolioRepository {
  const _FakePortfolioRepo();
  @override
  Future<PortfolioOverviewVm> getOverview() async => const PortfolioOverviewVm(
    pendingSummary: PendingSummaryVm(),
    quoteStatusSummary: QuoteStatusSummaryVm(),
    primaryHoldings: [],
    recentMovements: [],
  );
  @override
  Future<List<HoldingVm>> listHoldings() async => _holdings;
  @override
  Future<List<HoldingVm>> listHoldingsByAccount(Id accountId) async => [
    for (final h in _holdings)
      if (h.accountId == accountId) h,
  ];
  @override
  Future<AssetAllocationVm> getAssetAllocation() async =>
      const AssetAllocationVm(
        slices: [],
        totalAssets: Money(amount: '0', currency: 'CNY'),
        totalLiabilities: Money(amount: '0', currency: 'CNY'),
        netWorth: Money(amount: '0', currency: 'CNY'),
      );
}

Widget _formHost(MovementRepository movementRepo) => ProviderScope(
  overrides: [
    capabilitiesProvider.overrideWith((ref) async => _caps),
    accountsProvider.overrideWith((ref) async => _accounts),
    instrumentsProvider.overrideWith((ref) async => _instruments),
    portfolioRepositoryProvider.overrideWithValue(const _FakePortfolioRepo()),
    movementRepositoryProvider.overrideWithValue(movementRepo),
  ],
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const InvestmentTradePage()),
      ],
    ),
  ),
);

/// 高视口 pump：ListView 懒加载，视口够高才能让所有字段常驻可交互。
Future<void> _pumpForm(WidgetTester tester, MovementRepository repo) async {
  tester.view.physicalSize = const Size(900, 1700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_formHost(repo));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String label, String value) async {
  await tester.enterText(find.widgetWithText(TextField, label), value);
  await tester.pump();
}

Future<void> _pick(WidgetTester tester, Key fieldKey, String option) async {
  await tester.tap(find.byKey(fieldKey));
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

/// 填一个可提交的卖出表单（默认卖 4 股沪深300ETF，毛回款 40）。
Future<void> _fillSell(
  WidgetTester tester, {
  String quantity = '4',
  String gross = '40.00',
  String fee = '',
  String tax = '',
}) async {
  await tester.tap(find.text('卖出'));
  await tester.pumpAndSettle();
  await _pick(tester, kTradeCashAccountFieldKey, '招行储蓄卡');
  await _pick(tester, kTradeHoldingAccountFieldKey, 'A股券商');
  await _pick(tester, kTradeInstrumentFieldKey, '沪深300ETF · 510300');
  await _enter(tester, '成交数量', quantity);
  await _enter(tester, '卖出毛回款', gross);
  if (fee.isNotEmpty) await _enter(tester, '手续费（可选）', fee);
  if (tax.isNotEmpty) await _enter(tester, '税费（可选）', tax);
}

FilledButton _submitButton(WidgetTester tester, String label) =>
    tester.widget<FilledButton>(
      find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ),
    );

// —— saleResult / costBasisFx 展示宿主 ——
class _FakeDetailRepo implements MovementRepository {
  const _FakeDetailRepo(this.movement);
  final MovementVm movement;
  @override
  Future<MovementVm?> getMovement(Id id) async => movement;
  @override
  Future<List<MovementVm>> listRecentMovements({int limit = 20}) async =>
      const [];
  @override
  Future<ConfirmResultVm> createManualRecord(ManualRecordInput input) =>
      throw UnsupportedError('read only');
  @override
  Future<ConfirmResultVm> createTransfer(TransferInput input) =>
      throw UnsupportedError('read only');
  @override
  Future<ConfirmResultVm> reconcileBalance(ReconcileInput input) =>
      throw UnsupportedError('read only');
  @override
  Future<void> createCorrectionProposal(CreateCorrectionInput input) =>
      throw UnsupportedError('read only');
  @override
  Future<ConfirmResultVm> createInvestmentTrade(InvestmentTradeInput input) =>
      throw UnsupportedError('read only');
}

Widget _detailHost(MovementVm movement) => ProviderScope(
  overrides: [
    capabilitiesProvider.overrideWith((ref) async => _caps),
    accountsProvider.overrideWith((ref) async => _accounts),
    movementRepositoryProvider.overrideWithValue(_FakeDetailRepo(movement)),
  ],
  child: const MaterialApp(home: MovementDetailPage(movementId: 'mov_s')),
);

Map<String, dynamic> _sellMovementJson({
  required String status,
  Map<String, Object?>? extra,
  bool withFx = false,
}) => {
  'id': 'mov_s',
  'atomicGroupId': 'ag_s',
  'type': 'sell',
  'status': 'confirmed',
  'title': '卖出 沪深300ETF',
  'occurredAt': '2026-07-16T00:00:00Z',
  'entries': const [],
  'saleResult': {
    'costBasisMethod': 'average_cost',
    'grossProceeds': {'amount': '40.00', 'currency': 'CNY'},
    'feeAndTaxTotal': {'amount': '2.00', 'currency': 'CNY'},
    'netProceeds': {'amount': '38.00', 'currency': 'CNY'},
    'realizedPnlStatus': status,
    ...?extra,
    if (withFx)
      'fxBasis': {
        'baseCurrency': 'CNY',
        'quoteCurrency': 'USD',
        'rate': '0.14',
        'asOf': '2026-07-15T00:00:00Z',
        'sourceRateId': 'fx_internal_1',
        'source': 'manual_test',
        'inverted': false,
      },
  },
};

void main() {
  group('entries 映射（repository 层）', () {
    test('1+4. 买入 100+fee 2+tax 1 → 四条 entries；费用腿同账户同币种', () async {
      final h = _tradeRepo();
      final result = await h.repo.createInvestmentTrade(_buyInput);
      expect(result.ledgerWrite, isTrue);
      expect(h.requests.map((r) => r.url.path).toList(), [
        '/v1/movements/drafts',
        '/v1/movements/mov_1/submit-review',
        '/v1/atomic-groups/ag_1/confirm',
      ]);
      final body = _draftBody(h.requests);
      expect(body['type'], 'buy');
      expect(body['occurredAt'], '2026-07-16T10:30:00+08:00');
      expect(body['entries'], [
        {
          'accountId': 'a_cash',
          'amount': '100.00',
          'currency': 'CNY',
          'direction': 'out',
          'role': 'source',
        },
        {
          'accountId': 'a_hold',
          'instrumentId': 'inst_pos',
          'amount': '10',
          'currency': 'CNY',
          'direction': 'in',
          'role': 'destination',
        },
        {
          'accountId': 'a_cash',
          'amount': '2.00',
          'currency': 'CNY',
          'direction': 'out',
          'role': 'fee',
        },
        {
          'accountId': 'a_cash',
          'amount': '1.00',
          'currency': 'CNY',
          'direction': 'out',
          'role': 'tax',
        },
      ]);
      // 幂等键：三次写各有 key，格式一致。
      for (final req in h.requests) {
        expect(
          req.headers['idempotency-key'],
          matches(RegExp(r'^[0-9a-f]{32}$')),
        );
      }
    });

    test('2+4. 卖出 gross 40/fee 1/tax 1：方向与 role 正确、费用腿同账户同币种', () async {
      final h = _tradeRepo();
      await h.repo.createInvestmentTrade(
        const InvestmentTradeInput(
          side: TradeSide.sell,
          cashAccountId: 'a_cash',
          holdingAccountId: 'a_hold',
          instrumentId: 'inst_pos',
          quantity: '4',
          principalAmount: '40.00',
          cashCurrency: 'CNY',
          holdingCurrency: 'CNY',
          feeAmount: '1.00',
          taxAmount: '1.00',
          title: '卖出 沪深300ETF',
        ),
      );
      final body = _draftBody(h.requests);
      expect(body['type'], 'sell');
      final entries = (body['entries'] as List).cast<Map<String, dynamic>>();
      expect(entries, hasLength(4));
      // 现金毛回款：in/destination；持仓数量腿：out/source 带 instrumentId。
      expect(entries[0], {
        'accountId': 'a_cash',
        'amount': '40.00',
        'currency': 'CNY',
        'direction': 'in',
        'role': 'destination',
      });
      expect(entries[1], {
        'accountId': 'a_hold',
        'instrumentId': 'inst_pos',
        'amount': '4',
        'currency': 'CNY',
        'direction': 'out',
        'role': 'source',
      });
      // 费用与税费：现金流出，与主腿同资金账户、同币种。
      for (final (i, role) in const [(2, 'fee'), (3, 'tax')]) {
        expect(entries[i]['role'], role);
        expect(entries[i]['direction'], 'out');
        expect(entries[i]['accountId'], 'a_cash');
        expect(entries[i]['currency'], 'CNY');
        expect(entries[i].containsKey('instrumentId'), isFalse);
      }
    });

    test('3. fee/tax 空值或 0 不发送费用腿（禁止零金额腿）', () async {
      for (final (fee, tax) in const [
        (null, null),
        ('0', null),
        ('0.00', '0'),
        ('', '  '),
      ]) {
        final h = _tradeRepo();
        await h.repo.createInvestmentTrade(
          InvestmentTradeInput(
            side: TradeSide.buy,
            cashAccountId: 'a_cash',
            holdingAccountId: 'a_hold',
            instrumentId: 'inst_pos',
            quantity: '10',
            principalAmount: '100.00',
            cashCurrency: 'CNY',
            holdingCurrency: 'CNY',
            feeAmount: fee,
            taxAmount: tax,
            title: '无费用买入',
          ),
        );
        final entries = _draftBody(h.requests)['entries'] as List;
        expect(entries, hasLength(2), reason: 'fee=$fee tax=$tax');
        for (final e in entries.cast<Map<String, dynamic>>()) {
          expect(e['role'], isNot(anyOf('fee', 'tax')));
        }
      }
    });

    test('10. 401 refresh 重放：drafts 复用同一幂等键', () async {
      final store = MemoryAuthTokenStore();
      await store.write(
        const StoredAuthSession(
          accessToken: 'access_expired',
          refreshToken: 'refresh_old',
          expiresAt: '2026-07-17T12:00:00+08:00',
          deviceId: 'device_1',
        ),
      );
      final draftKeys = <String>[];
      final client = DevApiClient(
        'http://127.0.0.1:1',
        tokenStore: store,
        client: MockClient((req) async {
          const jsonHeaders = {
            'content-type': 'application/json; charset=utf-8',
          };
          if (req.url.path == '/v1/auth/refresh') {
            return http.Response(
              jsonEncode({
                'ok': true,
                'data': {
                  'accessToken': 'access_new',
                  'refreshToken': 'refresh_new',
                  'expiresAt': '2026-07-17T13:00:00+08:00',
                  'deviceId': 'device_1',
                },
              }),
              200,
              headers: jsonHeaders,
            );
          }
          if (req.url.path == '/v1/movements/drafts') {
            draftKeys.add(req.headers['idempotency-key']!);
            if (req.headers['authorization'] == 'Bearer access_expired') {
              return http.Response(jsonEncode({'ok': false}), 401);
            }
            return http.Response(
              jsonEncode({
                'ok': true,
                'data': {'id': 'mov_1', 'atomicGroupId': 'ag_1'},
              }),
              200,
              headers: jsonHeaders,
            );
          }
          return http.Response(
            jsonEncode({
              'ok': true,
              'data': {
                'atomicGroupId': 'ag_1',
                'confirmedMovementIds': ['mov_1'],
                'snapshotInvalidated': true,
                'ledgerWrite': true,
              },
            }),
            200,
            headers: jsonHeaders,
          );
        }),
      );
      final result = await LocalServerMovementRepository(
        client,
      ).createInvestmentTrade(_buyInput);
      expect(result.ledgerWrite, isTrue);
      expect(draftKeys, hasLength(2));
      expect(draftKeys[0], draftKeys[1]);
    });

    test('11. 400/409/403 抛出异常，不返回伪造的确认结果', () async {
      await expectLater(
        _tradeRepo(failStatus: 400).repo.createInvestmentTrade(_buyInput),
        throwsA(isA<ApiValidationException>()),
      );
      await expectLater(
        _tradeRepo(failStatus: 403).repo.createInvestmentTrade(_buyInput),
        throwsA(isA<ApiForbiddenException>()),
      );
      await expectLater(
        _tradeRepo(failStatus: 409).repo.createInvestmentTrade(_buyInput),
        throwsA(isA<ApiConflictException>()),
      );
    });
  });

  group('本地校验（纯函数）', () {
    test('5. 数量与金额：空/0/负数/非法/超 8 位小数全部拦截', () {
      for (final bad in ['', '0', '0.0', '-1', 'abc', '1.2.3', '1.234567890']) {
        expect(requiredDecimalError(bad, '成交数量'), isNotNull, reason: bad);
        expect(requiredDecimalError(bad, '成交价款'), isNotNull, reason: bad);
      }
      for (final ok in ['10', '0.5', '0.00000001', '12345.678']) {
        expect(requiredDecimalError(ok, '成交数量'), isNull, reason: ok);
      }
      // fee/tax：空合法；负数/非法/超 8 位小数拦截；0 合法（但不发腿）。
      for (final bad in ['-1', 'abc', '0.123456789']) {
        expect(optionalNonNegativeError(bad, '手续费'), isNotNull, reason: bad);
      }
      for (final ok in ['', '0', '2.00']) {
        expect(optionalNonNegativeError(ok, '税费'), isNull, reason: ok);
      }
    });

    test('6/7 基础：卖出费用超毛回款、数量超持仓的纯校验', () {
      expect(
        sellFeeTaxError(grossProceeds: '40', fee: '39', tax: '1.01'),
        isNotNull,
      );
      expect(sellFeeTaxError(grossProceeds: '40', fee: '39', tax: '1'), isNull);
      expect(sellQuantityError(quantity: '7', heldQuantity: '6'), isNotNull);
      expect(sellQuantityError(quantity: '6', heldQuantity: '6'), isNull);
    });
  });

  group('表单交互（widget 层）', () {
    testWidgets('6. 卖出 fee+tax > 毛回款：不可提交并给出原因', (tester) async {
      final h = _tradeRepo();
      await _pumpForm(tester, h.repo);
      await _fillSell(tester, gross: '40.00', fee: '39.00', tax: '1.01');
      expect(find.text('手续费与税费合计不能超过卖出毛回款'), findsOneWidget);
      expect(_submitButton(tester, '确认卖出').onPressed, isNull);
      // 降到毛回款以内即可提交。
      await _enter(tester, '税费（可选）', '1.00');
      expect(_submitButton(tester, '确认卖出').onPressed, isNotNull);
      expect(h.requests, isEmpty);
    });

    testWidgets('7. 卖出数量大于当前持仓：不可提交', (tester) async {
      final h = _tradeRepo();
      await _pumpForm(tester, h.repo);
      await _fillSell(tester, quantity: '7');
      expect(find.textContaining('卖出数量不能超过当前持仓'), findsOneWidget);
      expect(_submitButton(tester, '确认卖出').onPressed, isNull);
      await _enter(tester, '成交数量', '6');
      expect(_submitButton(tester, '确认卖出').onPressed, isNotNull);
      expect(h.requests, isEmpty);
    });

    testWidgets('8. 卖出标的只来自所选持仓账户的正数量持仓', (tester) async {
      final h = _tradeRepo();
      await _pumpForm(tester, h.repo);
      await tester.tap(find.text('卖出'));
      await tester.pumpAndSettle();
      await _pick(tester, kTradeHoldingAccountFieldKey, 'A股券商');
      await tester.tap(find.byKey(kTradeInstrumentFieldKey));
      await tester.pumpAndSettle();
      // 正数量持仓可选；零数量与他账户持仓不出现。
      expect(find.text('沪深300ETF · 510300'), findsOneWidget);
      expect(find.text('持有 6'), findsOneWidget);
      expect(find.text('中证500ETF · 510500'), findsNothing);
      expect(find.text('NVIDIA · NVDA'), findsNothing);
    });

    testWidgets('9. 买入从服务端标的中选择，不手填 wire ID', (tester) async {
      final h = _tradeRepo();
      await _pumpForm(tester, h.repo);
      // 表单没有任何要求输入标的 ID 的字段。
      expect(find.widgetWithText(TextField, '标的 ID'), findsNothing);
      expect(find.widgetWithText(TextField, 'instrumentId'), findsNothing);
      await _pick(tester, kTradeCashAccountFieldKey, '招行储蓄卡');
      await _pick(tester, kTradeHoldingAccountFieldKey, 'A股券商');
      await _pick(tester, kTradeInstrumentFieldKey, '沪深300ETF · 510300');
      await _enter(tester, '成交数量', '10');
      await _enter(tester, '成交价款', '100.00');
      await tester.tap(find.text('确认买入').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(kTradeConfirmDialogKey),
          matching: find.widgetWithText(FilledButton, '确认买入'),
        ),
      );
      await tester.pumpAndSettle();
      // instrumentId 来自选择器，不是用户输入。
      final body = _draftBody(h.requests);
      final entries = (body['entries'] as List).cast<Map<String, dynamic>>();
      expect(entries[1]['instrumentId'], 'inst_pos');
      // 摘要未填 → 自动生成"买入 <标的名称>"。
      expect(body['title'], '买入 沪深300ETF');
    });

    testWidgets('9b. 买入标的报价币种不被持仓账户支持时不可提交', (tester) async {
      final h = _tradeRepo();
      await _pumpForm(tester, h.repo);
      await _pick(tester, kTradeCashAccountFieldKey, '招行储蓄卡');
      await _pick(tester, kTradeHoldingAccountFieldKey, 'A股券商');
      // NVIDIA 报价币种 USD，而 A股券商只支持 CNY。
      await _pick(tester, kTradeInstrumentFieldKey, 'NVIDIA · NVDA');
      await _enter(tester, '成交数量', '1');
      await _enter(tester, '成交价款', '100.00');
      expect(find.textContaining('持仓账户不支持该标的的报价币种'), findsOneWidget);
      expect(_submitButton(tester, '确认买入').onPressed, isNull);
      // 换成 CNY 标的即可提交。
      await _pick(tester, kTradeInstrumentFieldKey, '沪深300ETF · 510300');
      expect(_submitButton(tester, '确认买入').onPressed, isNotNull);
      expect(h.requests, isEmpty);
    });

    testWidgets('11W. 服务端 409：显示错误、不显示已入账、表单不关闭', (tester) async {
      final h = _tradeRepo(failStatus: 409);
      await _pumpForm(tester, h.repo);
      await _fillSell(tester);
      await tester.tap(find.text('确认卖出').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(kTradeConfirmDialogKey),
          matching: find.widgetWithText(FilledButton, '确认卖出'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已入账'), findsNothing);
      expect(find.textContaining('数据已发生变化'), findsOneWidget);
      // 表单仍在（未 pop），用户输入未丢。
      expect(find.byType(InvestmentTradePage), findsOneWidget);
    });

    testWidgets('11N. 网络错误：表单保留并提示重试', (tester) async {
      final repo = _ThrowingTradeRepo(
        http.ClientException('connection refused'),
      );
      await _pumpForm(tester, repo);
      await _fillSell(tester);
      await tester.tap(find.text('确认卖出').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(kTradeConfirmDialogKey),
          matching: find.widgetWithText(FilledButton, '确认卖出'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('网络连接失败'), findsOneWidget);
      expect(find.text('已入账'), findsNothing);
      // 表单与输入保留。
      expect(find.byType(InvestmentTradePage), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
    });

    testWidgets('11F. 403：提示无记账权限', (tester) async {
      final repo = _ThrowingTradeRepo(
        ApiForbiddenException('/v1/movements/drafts'),
      );
      await _pumpForm(tester, repo);
      await _fillSell(tester);
      await tester.tap(find.text('确认卖出').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(kTradeConfirmDialogKey),
          matching: find.widgetWithText(FilledButton, '确认卖出'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('没有记账权限'), findsOneWidget);
      expect(find.text('已入账'), findsNothing);
    });

    testWidgets('12. ledgerWrite=false 不显示「已入账」', (tester) async {
      final h = _tradeRepo(ledgerWrite: false);
      await _pumpForm(tester, h.repo);
      await _fillSell(tester);
      await tester.tap(find.text('确认卖出').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(kTradeConfirmDialogKey),
          matching: find.widgetWithText(FilledButton, '确认卖出'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已入账'), findsNothing);
      expect(find.text('已提交为待确认候选，尚未入账'), findsOneWidget);
      expect(find.text('前往审核'), findsOneWidget);
      // 未真正入账：不当作完成，表单保留。
      expect(find.byType(InvestmentTradePage), findsOneWidget);
    });

    testWidgets('16. 360/1200/1440 无 overflow；桌面表单宽度受限', (tester) async {
      final h = _tradeRepo();
      for (final size in const [
        Size(360, 800),
        Size(1200, 800),
        Size(1440, 900),
      ]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_formHost(h.repo));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size');
        final formWidth = tester.getSize(find.byType(ListView)).width;
        if (size.width >= 1200) {
          expect(formWidth, lessThanOrEqualTo(kTradeFormMaxWidth));
        }
        // 卖出态同样不溢出。
        await tester.tap(find.text('卖出'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size sell');
      }
    });
  });

  group('saleResult / costBasisFx 映射与展示', () {
    test('13a. 四种状态的 wire 映射', () {
      expect(
        parseMovementData(
          _sellMovementJson(status: 'calculated'),
        ).saleResult!.realizedPnlStatus,
        RealizedPnlStatus.calculated,
      );
      expect(
        parseMovementData(
          _sellMovementJson(status: 'calculated_with_fx', withFx: true),
        ).saleResult!.realizedPnlStatus,
        RealizedPnlStatus.calculatedWithFx,
      );
      expect(
        parseMovementData(
          _sellMovementJson(status: 'cost_basis_unavailable'),
        ).saleResult!.realizedPnlStatus,
        RealizedPnlStatus.costBasisUnavailable,
      );
      expect(
        parseMovementData(
          _sellMovementJson(status: 'currency_mismatch'),
        ).saleResult!.realizedPnlStatus,
        RealizedPnlStatus.currencyMismatch,
      );
    });

    testWidgets('13b. calculated：展示盈亏；负值不丢符号', (tester) async {
      final m = parseMovementData(
        _sellMovementJson(
          status: 'calculated',
          extra: {
            'costBasisReleased': {'amount': '41.20', 'currency': 'CNY'},
            'realizedPnl': {'amount': '-3.20', 'currency': 'CNY'},
          },
        ),
      );
      await tester.pumpWidget(_detailHost(m));
      await tester.pumpAndSettle();
      expect(find.text('成交结果'), findsOneWidget);
      expect(find.text('已实现盈亏'), findsOneWidget);
      expect(find.text('−¥3.20'), findsOneWidget);
      expect(find.text('盈亏暂不可计算'), findsNothing);
    });

    testWidgets('13c. cost_basis_unavailable / currency_mismatch 的用户文案', (
      tester,
    ) async {
      await tester.pumpWidget(
        _detailHost(
          parseMovementData(
            _sellMovementJson(status: 'cost_basis_unavailable'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('盈亏暂不可计算'), findsOneWidget);
      expect(find.text('已实现盈亏'), findsNothing);

      await tester.pumpWidget(
        _detailHost(
          parseMovementData(_sellMovementJson(status: 'currency_mismatch')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('缺少成交时汇率'), findsOneWidget);
      expect(find.text('已实现盈亏'), findsNothing);
    });

    testWidgets('14. calculated_with_fx：展示服务端固化值与换算依据，不用当前汇率重算', (
      tester,
    ) async {
      final m = parseMovementData(
        _sellMovementJson(
          status: 'calculated_with_fx',
          withFx: true,
          extra: {
            'costBasisReleased': {'amount': '20.00', 'currency': 'USD'},
            'realizedPnl': {'amount': '-14.68', 'currency': 'USD'},
            'netProceedsInCostBasisCurrency': {
              'amount': '5.32',
              'currency': 'USD',
            },
          },
        ),
      );
      await tester.pumpWidget(_detailHost(m));
      await tester.pumpAndSettle();
      // 盈亏优先展示成本基础币种（USD 符号 \$），金额为服务端固化值。
      expect(find.text(r'−$14.68'), findsOneWidget);
      expect(find.text(r'$5.32'), findsOneWidget);
      // 换算依据可展开：汇率/时间/来源；不暴露内部 rate ID。
      await tester.tap(find.text('换算依据'));
      await tester.pumpAndSettle();
      expect(find.text('1 CNY = 0.14 USD'), findsOneWidget);
      expect(find.textContaining('2026-07-15'), findsOneWidget);
      expect(find.text('manual_test'), findsOneWidget);
      expect(find.textContaining('fx_internal_1'), findsNothing);
    });

    testWidgets('15. 旧 movement 缺少 saleResult/costBasisFx 正常渲染', (
      tester,
    ) async {
      final legacy = parseMovementData({
        'id': 'mov_s',
        'atomicGroupId': 'ag_old',
        'type': 'sell',
        'status': 'confirmed',
        'title': '历史卖出',
        'occurredAt': '2025-01-01T00:00:00Z',
        'entries': const [],
      });
      expect(legacy.saleResult, isNull);
      expect(legacy.costBasisFx, isNull);
      await tester.pumpWidget(_detailHost(legacy));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('历史卖出'), findsOneWidget);
      expect(find.text('成交结果'), findsNothing);
      expect(find.text('成本换算依据'), findsNothing);
    });
  });
}

/// 只用于错误路径的 fake：createInvestmentTrade 固定抛出给定异常。
class _ThrowingTradeRepo implements MovementRepository {
  _ThrowingTradeRepo(this.error);
  final Object error;
  @override
  Future<ConfirmResultVm> createInvestmentTrade(InvestmentTradeInput input) =>
      Future.error(error);
  @override
  Future<List<MovementVm>> listRecentMovements({int limit = 20}) async =>
      const [];
  @override
  Future<MovementVm?> getMovement(Id id) async => null;
  @override
  Future<ConfirmResultVm> createManualRecord(ManualRecordInput input) =>
      throw UnsupportedError('unused');
  @override
  Future<ConfirmResultVm> createTransfer(TransferInput input) =>
      throw UnsupportedError('unused');
  @override
  Future<ConfirmResultVm> reconcileBalance(ReconcileInput input) =>
      throw UnsupportedError('unused');
  @override
  Future<void> createCorrectionProposal(CreateCorrectionInput input) =>
      throw UnsupportedError('unused');
}
