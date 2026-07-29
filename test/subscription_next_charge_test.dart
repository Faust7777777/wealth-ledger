// 订阅开始日期与下次扣费日分离（2026-07-18 任务单）：
// VM/HTTP body 显式映射、新建默认联动、手动值保留、早于开始日期阻止、
// 编辑用服务端值初始化、400 用户化不暴露 wire 字段。
import 'dart:convert';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/subscription_form_page.dart';
import 'package:finwealth/features/subscription_form_validation.dart';
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
  canManageSubscriptions: true,
);

const _account = AccountVm(
  id: 'acct_cny',
  displayName: '招行储蓄卡',
  accountType: AccountType.bank,
  isLiability: false,
  defaultCurrency: 'CNY',
);

CreateSubscriptionInput _createInput({String? nextChargeDate}) =>
    CreateSubscriptionInput(
      displayName: 'ChatGPT Plus',
      provider: 'OpenAI',
      amount: const Money(amount: '20.00', currency: 'CNY'),
      paymentAccountId: 'acct_cny',
      billingCycle: const SubscriptionBillingCycleVm(
        unit: BillingUnit.month,
        interval: 1,
      ),
      startDate: '2026-07-18',
      nextChargeDate: nextChargeDate,
    );

/// 捕获真实 HTTP body 的订阅仓库。
({SubscriptionRepository repo, List<http.Request> requests}) _subRepo() {
  final requests = <http.Request>[];
  final client = DevApiClient(
    'http://127.0.0.1:1',
    client: MockClient((req) async {
      requests.add(req);
      return http.Response(
        jsonEncode({
          'ok': true,
          'data': {
            'id': 'sub_1',
            'displayName': 'ChatGPT Plus',
            'provider': 'OpenAI',
            'amount': {'amount': '20.00', 'currency': 'CNY'},
            'paymentAccountId': 'acct_cny',
            'billingCycle': {'unit': 'month', 'interval': 1},
            'billingAnchorDay': 17,
            'startDate': '2026-07-18',
            'nextChargeDate': '2026-08-17',
            'autoRenew': true,
            'reminderDaysBefore': 3,
            'status': 'active',
          },
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
  return (repo: LocalServerSubscriptionRepository(client), requests: requests);
}

class _CapturingSubRepo implements SubscriptionRepository {
  _CapturingSubRepo({this.onWrite});
  final Object? Function()? onWrite;
  CreateSubscriptionInput? created;
  UpdateSubscriptionInput? updated;

  SubscriptionVm get _vm => SubscriptionVm(
    id: 'sub_1',
    displayName: created?.displayName ?? '订阅',
    provider: 'OpenAI',
    amount: const Money(amount: '20.00', currency: 'CNY'),
    paymentAccountId: 'acct_cny',
    billingCycle: const SubscriptionBillingCycleVm(
      unit: BillingUnit.month,
      interval: 1,
    ),
    billingAnchorDay: 17,
    startDate: '2026-07-18',
    autoRenew: true,
    reminderDaysBefore: 3,
    status: SubscriptionStatus.active,
  );

  @override
  Future<SubscriptionVm> createSubscription(CreateSubscriptionInput i) async {
    final err = onWrite?.call();
    if (err != null) throw err;
    created = i;
    return _vm;
  }

  @override
  Future<SubscriptionVm> updateSubscription(
    Id id,
    UpdateSubscriptionInput i,
  ) async {
    final err = onWrite?.call();
    if (err != null) throw err;
    updated = i;
    return _vm;
  }

  @override
  Future<List<SubscriptionVm>> listSubscriptions() async => const [];
  @override
  Future<List<SubscriptionVm>> listUpcomingSubscriptions({
    int days = 30,
  }) async => const [];
  @override
  Future<SubscriptionVm> getSubscription(Id id) async => _vm;
  @override
  Future<SubscriptionVm> cancelSubscription(Id id) =>
      throw UnsupportedError('unused');
  @override
  Future<AiAtomicGroupVm> createChargeProposal(Id id) =>
      throw UnsupportedError('unused');
  @override
  Future<SubscriptionDueScanResultVm> scanDueChargeProposals({
    required IsoDate throughDate,
    int limit = 100,
  }) => throw UnsupportedError('unused');
}

Widget _formHost(_CapturingSubRepo repo, {SubscriptionVm? existing}) =>
    ProviderScope(
      overrides: [
        capabilitiesProvider.overrideWith((ref) async => _caps),
        accountsProvider.overrideWith((ref) async => const [_account]),
        subscriptionRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => SubscriptionFormPage(existing: existing),
            ),
          ],
        ),
      ),
    );

Future<void> _pumpForm(
  WidgetTester tester,
  _CapturingSubRepo repo, {
  SubscriptionVm? existing,
}) async {
  tester.view.physicalSize = const Size(900, 1900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_formHost(repo, existing: existing));
  await tester.pumpAndSettle();
}

Future<void> _fillRequired(WidgetTester tester) async {
  await tester.enterText(find.widgetWithText(TextField, '名称'), 'ChatGPT Plus');
  await tester.enterText(find.widgetWithText(TextField, '服务商'), 'OpenAI');
  await tester.enterText(find.widgetWithText(TextField, '原币金额'), '20.00');
  await tester.tap(find.text('付款账户'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('招行储蓄卡（CNY）').last);
  await tester.pumpAndSettle();
}

/// 打开第 [index] 个日期字段（0=订阅开始日期，1=下次扣费日）并点选当月某天。
Future<void> _pickDay(WidgetTester tester, int index, String day) async {
  await tester.tap(find.text('选择').at(index));
  await tester.pumpAndSettle();
  await tester.tap(find.text(day).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

String _today() {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${now.year}-${two(now.month)}-${two(now.day)}';
}

void main() {
  group('纯校验', () {
    test('nextChargeDateError：早于开始日期报错，等于/晚于/空通过', () {
      expect(nextChargeDateError('2026-07-01', '2026-07-18'), isNotNull);
      expect(nextChargeDateError('2026-07-18', '2026-07-18'), isNull);
      expect(nextChargeDateError('2026-08-17', '2026-07-18'), isNull);
      expect(nextChargeDateError(null, '2026-07-18'), isNull);
      expect(nextChargeDateError('', '2026-07-18'), isNull);
    });
  });

  group('HTTP body 映射', () {
    test('create 显式携带 nextChargeDate；null 时省略', () async {
      final withDate = _subRepo();
      await withDate.repo.createSubscription(
        _createInput(nextChargeDate: '2026-08-17'),
      );
      final body1 =
          jsonDecode(withDate.requests.single.body) as Map<String, dynamic>;
      expect(body1['startDate'], '2026-07-18');
      expect(body1['nextChargeDate'], '2026-08-17');

      final withoutDate = _subRepo();
      await withoutDate.repo.createSubscription(_createInput());
      final body2 =
          jsonDecode(withoutDate.requests.single.body) as Map<String, dynamic>;
      expect(body2.containsKey('nextChargeDate'), isFalse);
    });

    test('update 显式携带 nextChargeDate；null 时省略（交服务端顺延）', () async {
      UpdateSubscriptionInput updateInput(String? next) =>
          UpdateSubscriptionInput(
            displayName: 'ChatGPT Plus',
            provider: 'OpenAI',
            planName: null,
            amount: const Money(amount: '20.00', currency: 'CNY'),
            paymentAccountId: 'acct_cny',
            billingCycle: const SubscriptionBillingCycleVm(
              unit: BillingUnit.month,
              interval: 1,
            ),
            startDate: '2026-09-01',
            nextChargeDate: next,
            duration: null,
            endDate: null,
            autoRenew: true,
            reminderDaysBefore: 3,
            status: SubscriptionStatus.active,
            note: null,
          );

      final h = _subRepo();
      await h.repo.updateSubscription('sub_1', updateInput('2026-09-17'));
      final body = jsonDecode(h.requests.single.body) as Map<String, dynamic>;
      expect(body['nextChargeDate'], '2026-09-17');

      final h2 = _subRepo();
      await h2.repo.updateSubscription('sub_1', updateInput(null));
      final body2 = jsonDecode(h2.requests.single.body) as Map<String, dynamic>;
      expect(body2.containsKey('nextChargeDate'), isFalse);
    });
  });

  group('表单交互', () {
    testWidgets('新建默认：下次扣费日等于开始日期（今天）', (tester) async {
      final repo = _CapturingSubRepo();
      await _pumpForm(tester, repo);
      // 开始日期与下次扣费日两个字段都显示今天。
      expect(find.text('订阅开始日期'), findsOneWidget);
      expect(find.text('下次扣费日'), findsOneWidget);
      expect(find.text(_today()), findsNWidgets(2));
    });

    testWidgets('本月已续费：手动改下次扣费日为更晚日期并提交', (tester) async {
      final repo = _CapturingSubRepo();
      await _pumpForm(tester, repo);
      await _fillRequired(tester);
      // 下次扣费日（第 2 个日期字段）改到本月内比今天更晚的一天。
      // 用固定日期会在月末失效，这里按当天推导。
      final now = DateTime.now();
      final lastDay = DateTime(now.year, now.month + 1, 0).day;
      final targetDay = now.day < lastDay ? now.day + 1 : now.day;
      await _pickDay(tester, 1, '$targetDay');
      await tester.tap(find.widgetWithText(FilledButton, '创建订阅'));
      await tester.pumpAndSettle();
      final expected =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${targetDay.toString().padLeft(2, '0')}';
      expect(repo.created, isNotNull);
      expect(repo.created!.nextChargeDate, expected);
      expect(repo.created!.startDate, _today());
    });

    testWidgets('下次扣费日早于开始日期：阻止提交并显示中文错误', (tester) async {
      final repo = _CapturingSubRepo();
      await _pumpForm(tester, repo);
      await _fillRequired(tester);
      await _pickDay(tester, 1, '1');
      await tester.tap(find.widgetWithText(FilledButton, '创建订阅'));
      await tester.pumpAndSettle();
      expect(find.text('下次扣费日不能早于订阅开始日期'), findsOneWidget);
      expect(repo.created, isNull);
    });

    testWidgets('编辑：下次扣费日用服务端值初始化，不按今天猜测', (tester) async {
      final repo = _CapturingSubRepo();
      final existing = SubscriptionVm(
        id: 'sub_1',
        displayName: 'ChatGPT Plus',
        provider: 'OpenAI',
        amount: const Money(amount: '20.00', currency: 'CNY'),
        paymentAccountId: 'acct_cny',
        billingCycle: const SubscriptionBillingCycleVm(
          unit: BillingUnit.month,
          interval: 1,
        ),
        billingAnchorDay: 17,
        startDate: '2026-01-17',
        nextChargeDate: '2026-08-17',
        autoRenew: true,
        reminderDaysBefore: 3,
        status: SubscriptionStatus.active,
      );
      await _pumpForm(tester, repo, existing: existing);
      expect(find.text('2026-08-17'), findsOneWidget);
      expect(find.text('2026-01-17'), findsOneWidget);
      // 直接保存：提交的就是服务端值，不被今天覆盖。
      await tester.tap(find.widgetWithText(FilledButton, '保存修改'));
      await tester.pumpAndSettle();
      expect(repo.updated, isNotNull);
      expect(repo.updated!.nextChargeDate, '2026-08-17');
      expect(repo.updated!.startDate, '2026-01-17');
    });

    testWidgets('服务端 400（nextChargeDate 冲突）转成中文，不暴露 wire 字段', (tester) async {
      final repo = _CapturingSubRepo(
        onWrite: () => ApiValidationException(
          '/v1/subscriptions',
          message: 'Local ledger request is invalid.',
          details: const [
            'subscriptions[0].nextChargeDate must be on or after startDate',
          ],
        ),
      );
      await _pumpForm(tester, repo);
      await _fillRequired(tester);
      await tester.tap(find.widgetWithText(FilledButton, '创建订阅'));
      await tester.pumpAndSettle();
      expect(find.text('下次扣费日不能早于订阅开始日期'), findsOneWidget);
      expect(find.textContaining('subscriptions[0]'), findsNothing);
      expect(find.textContaining('must be on or after'), findsNothing);
    });

    testWidgets('360 与 1200 宽表单无 overflow', (tester) async {
      for (final size in const [Size(360, 800), Size(1200, 800)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final repo = _CapturingSubRepo();
        await tester.pumpWidget(_formHost(repo));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size');
      }
    });
  });
}
