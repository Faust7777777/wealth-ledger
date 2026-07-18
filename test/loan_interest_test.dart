// 贷款利率/应计利息/还款计划（2026-07-18 任务单）：
// 百分比↔wire 小数回归、条款 PATCH 与利息提案 body、头寸/计划映射、
// loan_interest 类型不落 adjustment 兜底、贷款区展示与 pending 门控、
// 还款计划分页与 balloon 展示、360/1200 无溢出。
import 'dart:convert';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/liability_terms_validation.dart';
import 'package:finwealth/features/loan_section.dart';
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

const _loanAccount = AccountVm(
  id: 'a_loan',
  displayName: '邮储助学贷款',
  accountType: AccountType.loan,
  isLiability: true,
  balanceMode: 'liability',
  defaultCurrency: 'CNY',
  cashBalances: {'CNY': '-400.00'},
);

Map<String, dynamic> _termsJson({bool pending = false}) => {
  'liabilityType': 'student_loan',
  'annualRate': '0.365',
  'rateType': 'fixed',
  'dayCountBasis': 365,
  'interestStartDate': '2026-01-01',
  'maturityDate': '2026-12-01',
  'repaymentStartDate': '2026-02-01',
  'nextDueDate': '2026-02-01',
  'repaymentFrequency': 'monthly',
  'scheduledPayment': {'amount': '100.00', 'currency': 'CNY'},
  'paymentAccountId': 'a_cash',
  'lastInterestAccruedThrough': '2026-01-01',
  if (pending) 'pendingLoanInterestMovementId': 'mov_pending_interest',
  if (pending) 'pendingLoanInterestThroughDate': '2026-01-31',
  'updatedAt': '2026-07-18T00:00:00Z',
};

Map<String, dynamic> _positionJson({bool pending = false}) => {
  'accountId': 'a_loan',
  'accountName': '邮储助学贷款',
  'currency': 'CNY',
  'terms': _termsJson(pending: pending),
  'outstandingPrincipal': {'amount': '400.00', 'currency': 'CNY'},
  'accruedThrough': '2026-01-31',
  'accrualDays': 30,
  'accruedInterest': {'amount': '12.00', 'currency': 'CNY'},
  'nextPayment': {
    'dueDate': '2026-02-01',
    'scheduledAmount': {'amount': '100.00', 'currency': 'CNY'},
    'projectedInterest': {'amount': '12.40', 'currency': 'CNY'},
    'projectedPrincipal': {'amount': '87.60', 'currency': 'CNY'},
  },
  'status': 'active',
};

Map<String, dynamic> _scheduleJson({bool hasMore = true}) => {
  'accountId': 'a_loan',
  'accountName': '邮储助学贷款',
  'currency': 'CNY',
  'generatedFrom': '2026-01-01',
  'maturityDate': '2026-12-01',
  'items': [
    {
      'sequence': 1,
      'dueDate': '2026-02-01',
      'accrualDays': 31,
      'openingBalance': {'amount': '400.00', 'currency': 'CNY'},
      'interest': {'amount': '12.40', 'currency': 'CNY'},
      'principal': {'amount': '87.60', 'currency': 'CNY'},
      'payment': {'amount': '100.00', 'currency': 'CNY'},
      'unpaidInterest': {'amount': '0', 'currency': 'CNY'},
      'closingBalance': {'amount': '312.40', 'currency': 'CNY'},
      'kind': 'scheduled',
    },
    {
      'sequence': 2,
      'dueDate': '2026-03-01',
      'accrualDays': 28,
      'openingBalance': {'amount': '312.40', 'currency': 'CNY'},
      'interest': {'amount': '8.7472', 'currency': 'CNY'},
      'principal': {'amount': '91.2528', 'currency': 'CNY'},
      'payment': {'amount': '100.00', 'currency': 'CNY'},
      'unpaidInterest': {'amount': '0', 'currency': 'CNY'},
      'closingBalance': {'amount': '221.1472', 'currency': 'CNY'},
      'kind': 'balloon',
    },
  ],
  'projectedTotals': {
    'payments': {'amount': '200.00', 'currency': 'CNY'},
    'interest': {'amount': '21.1472', 'currency': 'CNY'},
    'principal': {'amount': '178.8528', 'currency': 'CNY'},
  },
  'remainingBalanceAfterPage': {'amount': '221.1472', 'currency': 'CNY'},
  'hasMore': hasMore,
};

({LoanRepository repo, List<http.Request> requests}) _loanRepo({
  int failStatus = 0,
}) {
  final requests = <http.Request>[];
  final client = DevApiClient(
    'http://127.0.0.1:1',
    client: MockClient((req) async {
      requests.add(req);
      const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};
      if (failStatus != 0) {
        return http.Response(
          jsonEncode({
            'ok': false,
            'error': {'code': 'test', 'message': '拒绝（$failStatus）'},
          }),
          failStatus,
          headers: jsonHeaders,
        );
      }
      final path = req.url.path;
      final Object data;
      if (path.endsWith('/repayment-schedule')) {
        data = _scheduleJson();
      } else if (path.endsWith('/loan-interest-proposals')) {
        data = {
          'id': 'ag_interest_1',
          'title': '贷款利息',
          'operation': 'create',
          'status': 'pending',
        };
      } else if (path == '/v1/liability-positions') {
        data = [_positionJson()];
      } else {
        // PATCH liability-terms → Account
        data = {
          'id': 'a_loan',
          'displayName': '邮储助学贷款',
          'accountType': 'loan',
          'defaultCurrency': 'CNY',
          'supportedCurrencies': ['CNY'],
          'includeInNetWorth': true,
          'balanceMode': 'liability',
          'cashBalances': [],
          'status': 'active',
        };
      }
      return http.Response(
        jsonEncode({'ok': true, 'data': data}),
        200,
        headers: jsonHeaders,
      );
    }),
  );
  return (repo: LocalServerLoanRepository(client), requests: requests);
}

const _termsInput = LiabilityTermsInput(
  liabilityType: LiabilityType.studentLoan,
  annualRate: '0.0365',
  rateType: LiabilityRateType.floating,
  dayCountBasis: 360,
  interestStartDate: '2026-01-01',
  maturityDate: '2026-12-01',
  repaymentStartDate: '2026-02-01',
  nextDueDate: '2026-02-01',
  scheduledPayment: Money(amount: '100.00', currency: 'CNY'),
  paymentAccountId: 'a_cash',
);

class _FakeLoanRepo implements LoanRepository {
  _FakeLoanRepo({
    this.positions = const [],
    this.schedules = const [],
    this.onPropose,
  });
  final List<LiabilityPositionVm> positions;
  final List<LoanRepaymentScheduleVm> schedules;
  final Object? Function()? onPropose;
  final List<int> scheduleLimits = [];
  final List<String> proposedThroughDates = [];

  @override
  Future<List<LiabilityPositionVm>> listLiabilityPositions({
    IsoDate? throughDate,
  }) async => positions;
  @override
  Future<LoanRepaymentScheduleVm> getRepaymentSchedule(
    Id accountId, {
    int limit = 24,
  }) async {
    scheduleLimits.add(limit);
    return schedules[scheduleLimits.length.clamp(1, schedules.length) - 1];
  }

  @override
  Future<AccountVm> updateLiabilityTerms(
    Id accountId,
    LiabilityTermsInput input,
  ) => throw UnsupportedError('unused');
  @override
  Future<AiAtomicGroupVm> proposeLoanInterest(
    Id accountId, {
    required IsoDate throughDate,
    String? note,
  }) async {
    final err = onPropose?.call();
    if (err != null) throw err;
    proposedThroughDates.add(throughDate);
    return const AiAtomicGroupVm(
      id: 'ag_interest_1',
      title: '贷款利息',
      operation: AiOperation.create,
      status: AiGroupStatus.pending,
    );
  }
}

Widget _sectionHost(_FakeLoanRepo repo) => ProviderScope(
  overrides: [
    capabilitiesProvider.overrideWith((ref) async => _caps),
    loanRepositoryProvider.overrideWithValue(repo),
    aiPendingProvider.overrideWith((ref) async => const <AiProposalVm>[]),
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
          builder: (_, _) => const Scaffold(
            body: SingleChildScrollView(
              child: LoanSection(account: _loanAccount),
            ),
          ),
        ),
        GoRoute(path: '/ai-review', builder: (_, _) => const Placeholder()),
        GoRoute(
          path: '/account/:id/liability-terms',
          builder: (_, _) => const Placeholder(),
        ),
      ],
    ),
  ),
);

void main() {
  group('利率换算（必测 7 回归）', () {
    test('百分比 → wire 小数（左移两位，纯字符串）', () {
      expect(percentToWireRate('3.65'), '0.0365');
      expect(percentToWireRate('36.5'), '0.365');
      expect(percentToWireRate('12'), '0.12');
      expect(percentToWireRate('0.5'), '0.005');
      expect(percentToWireRate('100'), '1');
      expect(percentToWireRate('4.90'), '0.049');
    });

    test('wire 小数 → 百分比（右移两位）', () {
      expect(wireRateToPercent('0.0365'), '3.65');
      expect(wireRateToPercent('0.365'), '36.5');
      expect(wireRateToPercent('0.12'), '12');
      expect(wireRateToPercent('0.005'), '0.5');
      expect(wireRateToPercent('1'), '100');
    });

    test('年利率百分比校验', () {
      for (final bad in ['', '-1', 'abc', '3.1234567', '0']) {
        expect(annualRatePercentError(bad), isNotNull, reason: bad);
      }
      for (final ok in ['3.65', '36.5', '0.5']) {
        expect(annualRatePercentError(ok), isNull, reason: ok);
      }
    });
  });

  group('repository 映射', () {
    test('条款 PATCH body 逐字段正确（利率发 wire 小数）', () async {
      final h = _loanRepo();
      await h.repo.updateLiabilityTerms('a_loan', _termsInput);
      final req = h.requests.single;
      expect(req.method, 'PATCH');
      expect(req.url.path, '/v1/accounts/a_loan/liability-terms');
      expect(jsonDecode(req.body), {
        'liabilityType': 'student_loan',
        'annualRate': '0.0365',
        'rateType': 'floating',
        'dayCountBasis': 360,
        'interestStartDate': '2026-01-01',
        'maturityDate': '2026-12-01',
        'repaymentStartDate': '2026-02-01',
        'nextDueDate': '2026-02-01',
        'repaymentFrequency': 'monthly',
        'scheduledPayment': {'amount': '100.00', 'currency': 'CNY'},
        'paymentAccountId': 'a_cash',
      });
    });

    test('记录利息 body 与路径；409/400 抛类型化异常', () async {
      final h = _loanRepo();
      final group = await h.repo.proposeLoanInterest(
        'a_loan',
        throughDate: '2026-01-31',
        note: '一月利息',
      );
      expect(group.status, AiGroupStatus.pending);
      final req = h.requests.single;
      expect(req.url.path, '/v1/accounts/a_loan/loan-interest-proposals');
      expect(jsonDecode(req.body), {
        'throughDate': '2026-01-31',
        'note': '一月利息',
      });
      await expectLater(
        _loanRepo(
          failStatus: 409,
        ).repo.proposeLoanInterest('a_loan', throughDate: '2026-01-31'),
        throwsA(isA<ApiConflictException>()),
      );
      await expectLater(
        _loanRepo(
          failStatus: 400,
        ).repo.proposeLoanInterest('a_loan', throughDate: '2026-01-31'),
        throwsA(isA<ApiValidationException>()),
      );
    });

    test('头寸映射：应计 12 与下一期 12.4/87.6 分开（必测 2 口径）', () {
      final p = parseLiabilityPositionData(_positionJson());
      expect(p.outstandingPrincipal.amount, '400.00');
      expect(p.accruedInterest.amount, '12.00');
      expect(p.accrualDays, 30);
      expect(p.nextPayment.projectedInterest.amount, '12.40');
      expect(p.nextPayment.projectedPrincipal.amount, '87.60');
      expect(
        p.nextPayment.projectedInterest.amount,
        isNot(p.accruedInterest.amount),
      );
      expect(p.terms.rateType, LiabilityRateType.fixed);
      expect(p.terms.hasPendingInterest, isFalse);
      expect(
        parseLiabilityPositionData(
          _positionJson(pending: true),
        ).terms.hasPendingInterest,
        isTrue,
      );
    });

    test('还款计划映射（必测 6 数值 + balloon + hasMore）', () {
      final s = parseRepaymentScheduleData(_scheduleJson());
      expect(s.items, hasLength(2));
      expect(s.items[0].interest.amount, '12.40');
      expect(s.items[0].principal.amount, '87.60');
      expect(s.items[0].closingBalance.amount, '312.40');
      expect(s.items[1].interest.amount, '8.7472');
      expect(s.items[1].principal.amount, '91.2528');
      expect(s.items[1].closingBalance.amount, '221.1472');
      expect(s.items[1].kind, 'balloon');
      expect(s.hasMore, isTrue);
    });
  });

  group('loan_interest 类型（必测 5）', () {
    test('wire 映射不落 adjustment 兜底', () {
      final m = parseMovementData({
        'id': 'mov_li',
        'atomicGroupId': 'ag_li',
        'type': 'loan_interest',
        'status': 'confirmed',
        'title': '贷款利息',
        'occurredAt': '2026-01-31T00:00:00Z',
        'entries': const [],
      });
      expect(m.type, MovementType.loanInterest);
      expect(m.type, isNot(MovementType.adjustment));
    });

    testWidgets('流水详情显示「贷款利息」而不是「调整」', (tester) async {
      final m = parseMovementData({
        'id': 'mov_li',
        'atomicGroupId': 'ag_li',
        'type': 'loan_interest',
        'status': 'confirmed',
        'title': '1 月贷款利息',
        'occurredAt': '2026-01-31T00:00:00Z',
        'entries': const [],
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            capabilitiesProvider.overrideWith((ref) async => _caps),
            accountsProvider.overrideWith((ref) async => const [_loanAccount]),
            movementByIdProvider('mov_li').overrideWith((ref) async => m),
          ],
          child: const MaterialApp(
            home: MovementDetailPage(movementId: 'mov_li'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('贷款利息 · 2026-01-31'), findsOneWidget);
      expect(find.textContaining('调整'), findsNothing);
    });
  });

  group('贷款区展示与门控', () {
    testWidgets('头寸展示：债务/应计/下一期拆分；记录利息可用', (tester) async {
      final repo = _FakeLoanRepo(
        positions: [parseLiabilityPositionData(_positionJson())],
      );
      await tester.pumpWidget(_sectionHost(repo));
      await tester.pumpAndSettle();
      expect(find.text('¥400.00'), findsOneWidget);
      expect(find.textContaining('应计利息（截至 2026-01-31）'), findsOneWidget);
      expect(find.text('¥12.00'), findsOneWidget);
      expect(find.text('¥12.40'), findsOneWidget);
      expect(find.text('¥87.60'), findsOneWidget);
      final record = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('记录利息'),
          matching: find.byWidgetPredicate((w) => w is OutlinedButton),
        ),
      );
      expect(record.onPressed, isNotNull);
    });

    testWidgets('pending：记录利息与条款编辑禁用，给前往审核', (tester) async {
      final repo = _FakeLoanRepo(
        positions: [parseLiabilityPositionData(_positionJson(pending: true))],
      );
      await tester.pumpWidget(_sectionHost(repo));
      await tester.pumpAndSettle();
      final record = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('记录利息'),
          matching: find.byWidgetPredicate((w) => w is OutlinedButton),
        ),
      );
      expect(record.onPressed, isNull);
      final termsBtn = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('贷款条款'),
          matching: find.byWidgetPredicate((w) => w is TextButton),
        ),
      );
      expect(termsBtn.onPressed, isNull);
      expect(find.textContaining('已有待确认利息'), findsOneWidget);
      expect(find.text('前往审核'), findsOneWidget);
    });

    testWidgets('未配置条款：只有低强调入口', (tester) async {
      final repo = _FakeLoanRepo();
      await tester.pumpWidget(_sectionHost(repo));
      await tester.pumpAndSettle();
      expect(find.text('贷款条款'), findsOneWidget);
      expect(find.text('记录利息'), findsNothing);
      expect(find.text('剩余债务'), findsNothing);
    });

    testWidgets('记录利息弹窗：提交 throughDate（默认今天）', (tester) async {
      final repo = _FakeLoanRepo(
        positions: [parseLiabilityPositionData(_positionJson())],
      );
      await tester.pumpWidget(_sectionHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录利息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(repo.proposedThroughDates, hasLength(1));
      final now = DateTime.now();
      final today =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      expect(repo.proposedThroughDates.single, today);
      expect(find.text('已加入待确认'), findsOneWidget);
    });

    testWidgets('409：提示已有待确认利息，不显示成功', (tester) async {
      final repo = _FakeLoanRepo(
        positions: [parseLiabilityPositionData(_positionJson())],
        onPropose: () => ApiConflictException('/x', message: '冲突'),
      );
      await tester.pumpWidget(_sectionHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录利息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已有待确认利息'), findsOneWidget);
      expect(find.text('已加入待确认'), findsNothing);
    });

    testWidgets('还款计划：展开加载、balloon 显示「到期还款」、加载更多翻倍 limit', (tester) async {
      final schedule = parseRepaymentScheduleData(_scheduleJson());
      final more = parseRepaymentScheduleData(_scheduleJson(hasMore: false));
      final repo = _FakeLoanRepo(
        positions: [parseLiabilityPositionData(_positionJson())],
        schedules: [schedule, more],
      );
      await tester.pumpWidget(_sectionHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('还款计划'));
      await tester.pumpAndSettle();
      expect(repo.scheduleLimits, [24]);
      expect(find.textContaining('第 1 期 · 2026-02-01'), findsOneWidget);
      expect(find.textContaining('到期还款 · 2026-03-01'), findsOneWidget);
      expect(find.textContaining('本金 ¥87.60'), findsOneWidget);
      expect(find.textContaining('期末 ¥312.40'), findsOneWidget);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(repo.scheduleLimits, [24, 48]);
      expect(find.text('加载更多'), findsNothing);
    });

    testWidgets('360 与 1200 宽贷款区无溢出', (tester) async {
      for (final size in const [Size(360, 800), Size(1200, 800)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final repo = _FakeLoanRepo(
          positions: [parseLiabilityPositionData(_positionJson(pending: true))],
        );
        await tester.pumpWidget(_sectionHost(repo));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size');
      }
    });
  });
}
