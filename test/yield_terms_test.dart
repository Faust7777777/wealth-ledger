// 固定收益条款与计息（2026-07-18 任务单）：
// 百分比 ↔ wire 小数映射、单复利周期约束、wire 载荷映射、头寸读模型映射；
// 持仓详情低强调入口、服务端应计展示、pending 门控、400/409/网络失败处理、
// 360/1200 宽无 overflow。
import 'dart:io' show SocketException;

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/yield_section.dart';
import 'package:finwealth/features/yield_terms_page.dart';
import 'package:finwealth/features/yield_terms_validation.dart';
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

const _payoutAccount = AccountVm(
  id: 'a_payout',
  displayName: '招行储蓄卡',
  accountType: AccountType.bank,
  isLiability: false,
  defaultCurrency: 'CNY',
  balanceMode: 'cash_balance',
  cashBalances: {'CNY': '100.00'},
);

const _holding = HoldingVm(
  id: 'h_deposit',
  accountId: 'a_bank',
  instrumentId: 'inst_deposit',
  symbol: 'DEP',
  displayName: '一年期定存',
  quantity: '10000',
  quoteStatus: QuoteStatus.fresh,
);

YieldTermsVm _terms({
  String annualRate = '0.0365',
  YieldInterestMethod method = YieldInterestMethod.simple,
  YieldCompoundingFrequency frequency = YieldCompoundingFrequency.none,
  String? pendingMovementId,
  String? pendingThroughDate,
}) => YieldTermsVm(
  principal: const Money(amount: '10000.00', currency: 'CNY'),
  annualRate: annualRate,
  rateType: YieldRateType.fixed,
  interestMethod: method,
  dayCountBasis: 365,
  compoundingFrequency: frequency,
  interestStartDate: '2026-01-01',
  maturityDate: '2027-01-01',
  payoutAccountId: 'a_payout',
  lastAccruedThrough: '2026-01-01',
  updatedAt: '2026-01-01T00:00:00Z',
  pendingInterestMovementId: pendingMovementId,
  pendingInterestThroughDate: pendingThroughDate,
);

YieldPositionVm _position({
  YieldTermsVm? terms,
  String accruedInterest = '30.00',
  YieldPositionStatus status = YieldPositionStatus.active,
}) => YieldPositionVm(
  holdingId: 'h_deposit',
  accountId: 'a_bank',
  instrumentId: 'inst_deposit',
  instrumentName: '一年期定存',
  terms: terms ?? _terms(),
  accruedThrough: '2026-01-31',
  accrualDays: 30,
  fullCompoundingPeriods: 0,
  accruedInterest: Money(amount: accruedInterest, currency: 'CNY'),
  status: status,
);

class _FakeYieldRepo implements YieldRepository {
  _FakeYieldRepo({this.positions = const [], this.failure});
  final List<YieldPositionVm> positions;
  final Object? failure;
  final List<YieldTermsInput> savedTerms = [];
  final List<(String, String, String?)> proposals = [];

  @override
  Future<List<YieldPositionVm>> listYieldPositions({
    IsoDate? throughDate,
  }) async => positions;

  @override
  Future<HoldingVm> updateYieldTerms(
    Id holdingId,
    YieldTermsInput input,
  ) async {
    if (failure != null) throw failure!;
    savedTerms.add(input);
    return _holding;
  }

  @override
  Future<AiAtomicGroupVm> proposeInterest(
    Id holdingId, {
    required IsoDate throughDate,
    String? note,
  }) async {
    proposals.add((holdingId, throughDate, note));
    if (failure != null) throw failure!;
    return const AiAtomicGroupVm(
      id: 'ag_interest',
      title: '一年期定存利息',
      operation: AiOperation.create,
      status: AiGroupStatus.pending,
    );
  }
}

Widget _sectionHost(_FakeYieldRepo repo, {double width = 800}) => ProviderScope(
  overrides: [
    capabilitiesProvider.overrideWith((ref) async => _caps),
    yieldRepositoryProvider.overrideWithValue(repo),
    accountsProvider.overrideWith((ref) async => const [_payoutAccount]),
    holdingsProvider.overrideWith((ref) async => const [_holding]),
    overviewProvider.overrideWith(
      (ref) async => const PortfolioOverviewVm(
        pendingSummary: PendingSummaryVm(),
        quoteStatusSummary: QuoteStatusSummaryVm(),
        primaryHoldings: [],
        recentMovements: [],
      ),
    ),
    recentMovementsProvider.overrideWith((ref) async => const <MovementVm>[]),
    aiPendingProvider.overrideWith((ref) async => const <AiProposalVm>[]),
  ],
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: SizedBox(
              width: width,
              child: const SingleChildScrollView(
                child: YieldSection(holding: _holding),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/holding/:id/yield-terms',
          builder: (_, s) => YieldTermsPage(holdingId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/ai-review',
          builder: (_, _) => const Scaffold(body: Text('review-page')),
        ),
      ],
    ),
  ),
);

Widget _formHost(_FakeYieldRepo repo) => ProviderScope(
  overrides: [
    capabilitiesProvider.overrideWith((ref) async => _caps),
    yieldRepositoryProvider.overrideWithValue(repo),
    accountsProvider.overrideWith((ref) async => const [_payoutAccount]),
    holdingsProvider.overrideWith((ref) async => const [_holding]),
    overviewProvider.overrideWith(
      (ref) async => const PortfolioOverviewVm(
        pendingSummary: PendingSummaryVm(),
        quoteStatusSummary: QuoteStatusSummaryVm(),
        primaryHoldings: [],
        recentMovements: [],
      ),
    ),
  ],
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const YieldTermsPage(holdingId: 'h_deposit'),
        ),
      ],
    ),
  ),
);

/// 表单较长：用足够高的视口整屏渲染，避免断言受滚动位置影响。
void _tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Finder get _saveFinder => find.widgetWithText(FilledButton, '保存条款');

void main() {
  group('利率换算与条款校验', () {
    test('百分比 → wire 小数：不经 double', () {
      expect(percentToWireRate('3.65'), '0.0365');
      expect(percentToWireRate('0.5'), '0.005');
      expect(percentToWireRate('12'), '0.12');
      expect(percentToWireRate('100'), '1');
      expect(percentToWireRate('2.875'), '0.02875');
    });

    test('wire 小数 → 百分比：往返一致', () {
      expect(wireRateToPercent('0.0365'), '3.65');
      expect(wireRateToPercent('0.005'), '0.5');
      expect(wireRateToPercent('1'), '100');
      for (final p in ['3.65', '0.5', '12', '2.875']) {
        expect(wireRateToPercent(percentToWireRate(p)), p, reason: p);
      }
    });

    test('单利必须 none，复利必须选周期', () {
      expect(
        compoundingFrequencyError(
          YieldInterestMethod.simple,
          YieldCompoundingFrequency.none,
        ),
        isNull,
      );
      expect(
        compoundingFrequencyError(
          YieldInterestMethod.simple,
          YieldCompoundingFrequency.monthly,
        ),
        '单利不设复利周期',
      );
      expect(
        compoundingFrequencyError(
          YieldInterestMethod.compound,
          YieldCompoundingFrequency.none,
        ),
        '请选择复利周期',
      );
      expect(
        compoundingFrequencyError(
          YieldInterestMethod.compound,
          YieldCompoundingFrequency.quarterly,
        ),
        isNull,
      );
    });

    test('计息截止日期须晚于上次应计日期', () {
      expect(throughDateAfterAccruedError('2026-01-31', '2026-01-01'), isNull);
      expect(
        throughDateAfterAccruedError('2026-01-01', '2026-01-01'),
        contains('2026-01-01'),
      );
    });
  });

  group('wire 载荷与读模型映射', () {
    test('条款载荷：单利发 none，年利率发十进制小数', () {
      final body = yieldTermsBody(
        YieldTermsInput(
          principal: const Money(amount: '10000', currency: 'CNY'),
          annualRate: percentToWireRate('3.65'),
          rateType: YieldRateType.fixed,
          interestMethod: YieldInterestMethod.simple,
          dayCountBasis: 365,
          compoundingFrequency: YieldCompoundingFrequency.none,
          interestStartDate: '2026-01-01',
          maturityDate: '2027-01-01',
          payoutAccountId: 'a_payout',
        ),
      );
      expect(body['annualRate'], '0.0365');
      expect(body['interestMethod'], 'simple');
      expect(body['compoundingFrequency'], 'none');
      expect(body['dayCountBasis'], 365);
      expect(body['principal'], {'amount': '10000', 'currency': 'CNY'});
    });

    test('复利载荷：周期按枚举发 monthly/quarterly/annual', () {
      for (final (f, wire) in const [
        (YieldCompoundingFrequency.monthly, 'monthly'),
        (YieldCompoundingFrequency.quarterly, 'quarterly'),
        (YieldCompoundingFrequency.annual, 'annual'),
      ]) {
        final body = yieldTermsBody(
          YieldTermsInput(
            principal: const Money(amount: '10000', currency: 'CNY'),
            annualRate: '0.0365',
            rateType: YieldRateType.floating,
            interestMethod: YieldInterestMethod.compound,
            dayCountBasis: 360,
            compoundingFrequency: f,
            interestStartDate: '2026-01-01',
            maturityDate: '2027-01-01',
            payoutAccountId: 'a_payout',
          ),
        );
        expect(body['compoundingFrequency'], wire);
        expect(body['interestMethod'], 'compound');
        expect(body['rateType'], 'floating');
        expect(body['dayCountBasis'], 360);
      }
    });

    test('头寸读模型：应计与状态原样映射', () {
      final vm = parseYieldPositionData({
        'holdingId': 'h_deposit',
        'accountId': 'a_bank',
        'instrumentId': 'inst_deposit',
        'instrumentName': '一年期定存',
        'terms': {
          'principal': {'amount': '10000', 'currency': 'CNY'},
          'annualRate': '0.0365',
          'rateType': 'fixed',
          'interestMethod': 'simple',
          'dayCountBasis': 365,
          'compoundingFrequency': 'none',
          'interestStartDate': '2026-01-01',
          'maturityDate': '2027-01-01',
          'payoutAccountId': 'a_payout',
          'lastAccruedThrough': '2026-01-01',
          'updatedAt': '2026-01-01T00:00:00Z',
          'pendingInterestMovementId': 'mov_1',
          'pendingInterestThroughDate': '2026-01-31',
        },
        'accruedThrough': '2026-01-31',
        'accrualDays': 30,
        'fullCompoundingPeriods': 0,
        'accruedInterest': {'amount': '30', 'currency': 'CNY'},
        'status': 'matured',
      });
      expect(vm.accrualDays, 30);
      expect(vm.accruedInterest.amount, '30');
      expect(vm.status, YieldPositionStatus.matured);
      expect(vm.terms.hasPendingInterest, isTrue);
      expect(vm.terms.pendingInterestThroughDate, '2026-01-31');
      expect(wireRateToPercent(vm.terms.annualRate), '3.65');
    });
  });

  group('持仓详情的收益区', () {
    testWidgets('未配置条款：只有低强调「收益条款」入口', (tester) async {
      await tester.pumpWidget(_sectionHost(_FakeYieldRepo()));
      await tester.pumpAndSettle();
      expect(find.text('收益条款'), findsOneWidget);
      expect(find.text('记录利息'), findsNothing);
      expect(find.text('本金'), findsNothing);
    });

    testWidgets('已配置：展示服务端本金/年利率/应计/截至日期，可记录利息', (tester) async {
      await tester.pumpWidget(
        _sectionHost(_FakeYieldRepo(positions: [_position()])),
      );
      await tester.pumpAndSettle();
      expect(find.text('本金'), findsOneWidget);
      expect(find.text('¥10,000.00'), findsOneWidget);
      expect(find.text('3.65% · 单利 · 365 天'), findsOneWidget);
      expect(find.text('应计利息（截至 2026-01-31）'), findsOneWidget);
      expect(find.text('¥30.00'), findsOneWidget);
      expect(find.text('起息日'), findsOneWidget);
      expect(find.text('2027-01-01'), findsOneWidget);
      final record = find.widgetWithText(OutlinedButton, '记录利息');
      expect(tester.widget<OutlinedButton>(record).onPressed, isNotNull);
    });

    testWidgets('复利头寸：展示复利周期', (tester) async {
      await tester.pumpWidget(
        _sectionHost(
          _FakeYieldRepo(
            positions: [
              _position(
                terms: _terms(
                  method: YieldInterestMethod.compound,
                  frequency: YieldCompoundingFrequency.monthly,
                ),
                accruedInterest: '30.42',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('3.65% · 复利 按月 · 365 天'), findsOneWidget);
      expect(find.text('¥30.42'), findsOneWidget);
    });

    testWidgets('pending：禁止重复提交与编辑条款，引导去审核', (tester) async {
      await tester.pumpWidget(
        _sectionHost(
          _FakeYieldRepo(
            positions: [
              _position(
                terms: _terms(
                  pendingMovementId: 'mov_1',
                  pendingThroughDate: '2026-01-31',
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '记录利息'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '编辑'))
            .onPressed,
        isNull,
      );
      expect(find.text('已有待确认利息（截至 2026-01-31）'), findsOneWidget);
      await tester.tap(find.text('前往审核'));
      await tester.pumpAndSettle();
      expect(find.text('review-page'), findsOneWidget);
    });

    testWidgets('记录利息成功：只显示「已加入待确认」', (tester) async {
      final repo = _FakeYieldRepo(positions: [_position()]);
      await tester.pumpWidget(_sectionHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录利息'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '提交'));
      await tester.pumpAndSettle();
      expect(repo.proposals, hasLength(1));
      expect(repo.proposals.single.$1, 'h_deposit');
      expect(find.text('已加入待确认'), findsOneWidget);
      // 不出现前端自算的收益数字。
      expect(find.textContaining('预计收益'), findsNothing);
    });

    testWidgets('记录利息 409：提示数据已变化并可重新加载', (tester) async {
      final repo = _FakeYieldRepo(
        positions: [_position()],
        failure: ApiConflictException(
          '/v1/holdings/h_deposit/interest-proposals',
          code: 'conflict',
          message: 'holding already has a pending interest proposal',
        ),
      );
      await tester.pumpWidget(_sectionHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录利息'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '提交'));
      await tester.pumpAndSettle();
      expect(find.textContaining('数据已发生变化或已有待确认利息'), findsOneWidget);
      expect(find.text('重新加载'), findsOneWidget);
    });

    testWidgets('360 与 1200 宽无 overflow', (tester) async {
      for (final width in [360.0, 1200.0]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _sectionHost(
            _FakeYieldRepo(
              positions: [
                _position(
                  terms: _terms(
                    method: YieldInterestMethod.compound,
                    frequency: YieldCompoundingFrequency.quarterly,
                    pendingMovementId: 'mov_1',
                    pendingThroughDate: '2026-01-31',
                  ),
                ),
              ],
            ),
            width: width,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'width=$width');
      }
    });
  });

  group('收益条款表单', () {
    testWidgets('回填已有条款：年利率显示百分比', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(
        _formHost(_FakeYieldRepo(positions: [_position()])),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '3.65'), findsOneWidget);
      expect(find.widgetWithText(TextField, '10000.00'), findsOneWidget);
      expect(find.text('2026-01-01'), findsOneWidget);
    });

    testWidgets('保存：3.65% 发送 0.0365', (tester) async {
      final repo = _FakeYieldRepo(positions: [_position()]);
      _tallViewport(tester);
      await tester.pumpWidget(_formHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(_saveFinder);
      await tester.pumpAndSettle();
      expect(repo.savedTerms, hasLength(1));
      expect(repo.savedTerms.single.annualRate, '0.0365');
      expect(repo.savedTerms.single.principal.amount, '10000.00');
      expect(
        repo.savedTerms.single.compoundingFrequency,
        YieldCompoundingFrequency.none,
      );
    });

    testWidgets('400：显示字段原因', (tester) async {
      final repo = _FakeYieldRepo(
        positions: [_position()],
        failure: ApiValidationException(
          '/v1/holdings/h_deposit/yield-terms',
          message: 'invalid input',
          details: const ['principal.amount must be positive'],
        ),
      );
      _tallViewport(tester);
      await tester.pumpWidget(_formHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(_saveFinder);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('principal.amount must be positive'),
        findsOneWidget,
      );
    });

    testWidgets('网络失败：表单内容保留', (tester) async {
      final repo = _FakeYieldRepo(
        positions: [_position()],
        failure: const SocketException('connection refused'),
      );
      _tallViewport(tester);
      await tester.pumpWidget(_formHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(_saveFinder);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '3.65'), findsOneWidget);
      expect(find.widgetWithText(TextField, '10000.00'), findsOneWidget);
    });

    testWidgets('pending：保存按钮禁用', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(
        _formHost(
          _FakeYieldRepo(
            positions: [_position(terms: _terms(pendingMovementId: 'mov_1'))],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存条款'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('切到复利：出现复利周期选择并随载荷发送', (tester) async {
      final repo = _FakeYieldRepo(positions: [_position()]);
      _tallViewport(tester);
      await tester.pumpWidget(_formHost(repo));
      await tester.pumpAndSettle();
      expect(find.text('复利周期'), findsNothing);
      await tester.tap(find.text('复利'));
      await tester.pumpAndSettle();
      expect(find.text('复利周期'), findsOneWidget);
      await tester.tap(_saveFinder);
      await tester.pumpAndSettle();
      expect(
        repo.savedTerms.single.compoundingFrequency,
        YieldCompoundingFrequency.monthly,
      );
      expect(
        repo.savedTerms.single.interestMethod,
        YieldInterestMethod.compound,
      );
    });

    testWidgets('360 与 1200 宽表单无 overflow', (tester) async {
      for (final width in [360.0, 1200.0]) {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _formHost(_FakeYieldRepo(positions: [_position()])),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'width=$width');
      }
    });
  });
}
