import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _baseUrl = String.fromEnvironment('LOCAL_SERVER_API_BASE');

Map<String, dynamic> _map(Object? value) =>
    (value as Map).cast<String, dynamic>();

String _cashBalance(Object? account, String currency) {
  final balances = (_map(account)['cashBalances'] as List).cast<Object?>();
  final balance = balances
      .map(_map)
      .firstWhere((item) => item['currency'] == currency);
  return '${balance['amount']}';
}

void main() {
  test(
    'Flutter repository completes the local-server foreign-currency subscription flow',
    () async {
      final client = DevApiClient(_baseUrl);
      final account = _map(
        await client.postData(
          '/v1/accounts',
          body: {
            'displayName': 'Integration USD Card',
            'accountType': 'virtual_card',
            'defaultCurrency': 'USD',
            'supportedCurrencies': ['USD'],
            'includeInNetWorth': true,
            'balanceMode': 'cash_balance',
            'openingBalances': [
              {'currency': 'USD', 'amount': '100.00', 'quality': 'exact'},
            ],
          },
        ),
      );
      final accountId = '${account['id']}';
      final repository = LocalServerSubscriptionRepository(client);

      final created = await repository.createSubscription(
        CreateSubscriptionInput(
          displayName: 'ChatGPT Plus integration',
          provider: 'OpenAI',
          planName: 'Plus',
          amount: const Money(amount: '20.00', currency: 'USD'),
          paymentAccountId: accountId,
          billingCycle: const SubscriptionBillingCycleVm(
            unit: BillingUnit.month,
            interval: 1,
          ),
          startDate: '2026-01-31',
          duration: const SubscriptionDurationVm(
            unit: SubscriptionDurationUnit.month,
            count: 3,
          ),
          autoRenew: false,
          reminderDaysBefore: 3,
        ),
      );
      expect(created.amount.amount, '20.00');
      expect(created.amount.currency, 'USD');
      expect(created.billingAnchorDay, 31);
      expect(created.nextChargeDate, '2026-01-31');
      expect(
        (await repository.listUpcomingSubscriptions(
          days: 365,
        )).map((item) => item.id),
        contains(created.id),
      );

      final updated = await repository.updateSubscription(
        created.id,
        UpdateSubscriptionInput(
          displayName: created.displayName,
          provider: created.provider,
          planName: 'Plus edited',
          amount: created.amount,
          paymentAccountId: created.paymentAccountId,
          billingCycle: created.billingCycle,
          nextChargeDate: created.nextChargeDate,
          startDate: created.startDate,
          duration: null,
          endDate: '2026-04-30',
          autoRenew: true,
          reminderDaysBefore: 5,
          status: created.status,
          note: 'Local-server integration edit',
        ),
      );
      expect(updated.planName, 'Plus edited');
      expect(updated.duration, isNull);
      expect(updated.endDate, '2026-04-30');
      expect(updated.autoRenew, isTrue);
      expect(updated.reminderDaysBefore, 5);

      final firstGroup = await repository.createChargeProposal(created.id);
      expect(firstGroup.status, AiGroupStatus.pending);
      expect(
        _cashBalance(await client.getData('/v1/accounts/$accountId'), 'USD'),
        '100.00',
      );

      final confirmation = _map(
        await client.postData('/v1/atomic-groups/${firstGroup.id}/confirm'),
      );
      expect(confirmation['ledgerWrite'], isTrue);
      expect(
        _cashBalance(await client.getData('/v1/accounts/$accountId'), 'USD'),
        '80.00',
      );
      final afterFirst = await repository.getSubscription(created.id);
      expect(afterFirst.lastChargeDate, '2026-01-31');
      expect(afterFirst.nextChargeDate, '2026-02-28');

      final secondGroup = await repository.createChargeProposal(created.id);
      await expectLater(
        repository.createChargeProposal(created.id),
        throwsA(isA<ApiConflictException>()),
      );
      await expectLater(
        repository.cancelSubscription(created.id),
        throwsA(isA<ApiConflictException>()),
      );

      await client.postData('/v1/atomic-groups/${secondGroup.id}/reject');
      final retryGroup = await repository.createChargeProposal(created.id);
      expect(retryGroup.status, AiGroupStatus.pending);
      await client.postData('/v1/atomic-groups/${retryGroup.id}/reject');

      final cancelled = await repository.cancelSubscription(created.id);
      expect(cancelled.status, SubscriptionStatus.cancelled);
      expect(cancelled.nextChargeDate, isNull);
      expect(
        _cashBalance(await client.getData('/v1/accounts/$accountId'), 'USD'),
        '80.00',
      );
    },
    skip: _baseUrl.isEmpty
        ? 'Set LOCAL_SERVER_API_BASE through --dart-define; run tools/frontend_local_server_smoke.ps1.'
        : false,
  );

  test(
    'due-scan proposes only due subscriptions and defers charging to confirmation',
    () async {
      final client = DevApiClient(_baseUrl);
      final account = _map(
        await client.postData(
          '/v1/accounts',
          body: {
            'displayName': 'Due Scan USD Card',
            'accountType': 'virtual_card',
            'defaultCurrency': 'USD',
            'supportedCurrencies': ['USD'],
            'includeInNetWorth': true,
            'balanceMode': 'cash_balance',
            'openingBalances': [
              {'currency': 'USD', 'amount': '100.00', 'quality': 'exact'},
            ],
          },
        ),
      );
      final accountId = '${account['id']}';
      final repository = LocalServerSubscriptionRepository(client);

      CreateSubscriptionInput input(String name, String startDate) =>
          CreateSubscriptionInput(
            displayName: name,
            provider: 'OpenAI',
            planName: 'Plus',
            amount: const Money(amount: '20.00', currency: 'USD'),
            paymentAccountId: accountId,
            billingCycle: const SubscriptionBillingCycleVm(
              unit: BillingUnit.month,
              interval: 1,
            ),
            startDate: startDate,
            autoRenew: false,
            reminderDaysBefore: 3,
          );

      final due = await repository.createSubscription(
        input('Due scan target', '2026-01-05'),
      );
      final future = await repository.createSubscription(
        input('Future plan untouched', '2099-01-05'),
      );
      expect(due.nextChargeDate, '2026-01-05');
      expect(future.nextChargeDate, '2099-01-05');

      // 1) 只为到期项生成候选；未来项不动。
      final scan = await repository.scanDueChargeProposals(
        throughDate: '2026-07-13',
      );
      expect(scan.createdCount, 1);
      expect(scan.created.single.subscriptionId, due.id);
      expect(scan.created.single.scheduledChargeDate, '2026-01-05');
      expect(scan.created.single.group.status, AiGroupStatus.pending);
      expect(scan.skipped, isEmpty);
      expect(scan.hasMore, isFalse);
      expect(scan.remainingEligibleCount, 0);

      // 2) 扫描后余额、lastChargeDate、nextChargeDate 均不变。
      expect(
        _cashBalance(await client.getData('/v1/accounts/$accountId'), 'USD'),
        '100.00',
      );
      final afterScan = await repository.getSubscription(due.id);
      expect(afterScan.lastChargeDate, isNull);
      expect(afterScan.nextChargeDate, '2026-01-05');
      expect(afterScan.hasPendingCharge, isTrue);
      final futureAfterScan = await repository.getSubscription(future.id);
      expect(futureAfterScan.hasPendingCharge, isFalse);
      expect(futureAfterScan.nextChargeDate, '2099-01-05');

      // 3) AI pending 投影可读取新候选（standalone pending movement 投影）。
      final groupId = scan.created.single.group.id;
      final pendingProposals =
          (await client.getData('/v1/ai/proposals/pending') as List)
              .map((p) => _map(p))
              .toList();
      final pendingGroupIds = [
        for (final p in pendingProposals)
          for (final g in (p['atomicGroups'] as List)) '${_map(g)['id']}',
      ];
      expect(pendingGroupIds, contains(groupId));

      // 4) 重扫不重复建：already_pending 跳过。
      final rescan = await repository.scanDueChargeProposals(
        throughDate: '2026-07-13',
      );
      expect(rescan.createdCount, 0);
      expect(rescan.alreadyPendingCount, 1);
      expect(
        rescan.skipped.single.reason,
        SubscriptionDueScanSkipReason.alreadyPending,
      );
      expect(rescan.skipped.single.subscriptionId, due.id);

      // 5) 用户确认后才扣款并推进日期。
      await client.postData('/v1/atomic-groups/$groupId/confirm');
      expect(
        _cashBalance(await client.getData('/v1/accounts/$accountId'), 'USD'),
        '80.00',
      );
      final afterConfirm = await repository.getSubscription(due.id);
      expect(afterConfirm.lastChargeDate, '2026-01-05');
      expect(afterConfirm.nextChargeDate, '2026-02-05');
      expect(afterConfirm.hasPendingCharge, isFalse);
    },
    skip: _baseUrl.isEmpty
        ? 'Set LOCAL_SERVER_API_BASE through --dart-define; run tools/frontend_local_server_smoke.ps1.'
        : false,
  );

  test(
    'next charge date is independent from start date and advances on edit',
    () async {
      final client = DevApiClient(_baseUrl);
      final account = _map(
        await client.postData(
          '/v1/accounts',
          body: {
            'displayName': 'NextCharge CNY Card',
            'accountType': 'bank',
            'defaultCurrency': 'CNY',
            'supportedCurrencies': ['CNY'],
            'includeInNetWorth': true,
            'balanceMode': 'cash_balance',
            'openingBalances': [
              {'currency': 'CNY', 'amount': '100.00', 'quality': 'exact'},
            ],
          },
        ),
      );
      final repository = LocalServerSubscriptionRepository(client);

      // 本月已续费：开始日期今天、下次扣费直接填下月 17 日。
      final created = await repository.createSubscription(
        CreateSubscriptionInput(
          displayName: 'NextCharge integration',
          provider: 'OpenAI',
          amount: const Money(amount: '20.00', currency: 'CNY'),
          paymentAccountId: '${account['id']}',
          billingCycle: const SubscriptionBillingCycleVm(
            unit: BillingUnit.month,
            interval: 1,
          ),
          startDate: '2026-07-18',
          nextChargeDate: '2026-08-17',
        ),
      );
      expect(created.startDate, '2026-07-18');
      expect(created.nextChargeDate, '2026-08-17');

      // 编辑：开始日期移到旧 nextChargeDate 之后、不显式改下次扣费日 →
      // 服务端把下次扣费日顺延到新开始日期。
      final updated = await repository.updateSubscription(
        created.id,
        UpdateSubscriptionInput(
          displayName: created.displayName,
          provider: created.provider,
          planName: created.planName,
          amount: created.amount,
          paymentAccountId: created.paymentAccountId,
          billingCycle: created.billingCycle,
          startDate: '2026-09-01',
          nextChargeDate: null,
          duration: null,
          endDate: null,
          autoRenew: created.autoRenew,
          reminderDaysBefore: created.reminderDaysBefore,
          status: created.status,
          note: null,
        ),
      );
      expect(updated.startDate, '2026-09-01');
      expect(updated.nextChargeDate, '2026-09-01');

      // 显式选择晚于开始日期的下次扣费日：原值保留。
      final explicit = await repository.updateSubscription(
        created.id,
        UpdateSubscriptionInput(
          displayName: created.displayName,
          provider: created.provider,
          planName: created.planName,
          amount: created.amount,
          paymentAccountId: created.paymentAccountId,
          billingCycle: created.billingCycle,
          startDate: '2026-09-01',
          nextChargeDate: '2026-10-17',
          duration: null,
          endDate: null,
          autoRenew: created.autoRenew,
          reminderDaysBefore: created.reminderDaysBefore,
          status: created.status,
          note: null,
        ),
      );
      expect(explicit.nextChargeDate, '2026-10-17');
    },
    skip: _baseUrl.isEmpty
        ? 'Set LOCAL_SERVER_API_BASE through --dart-define; run tools/frontend_local_server_smoke.ps1.'
        : false,
  );
}
