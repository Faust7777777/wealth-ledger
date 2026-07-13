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
}
