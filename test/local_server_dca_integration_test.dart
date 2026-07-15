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

List<Map<String, dynamic>> _holdingsOf(Object? data, String accountId) => [
  for (final h in (data as List))
    if ('${_map(h)['accountId']}' == accountId) _map(h),
];

Set<String> _pendingGroupIds(Object? data) => {
  for (final p in (data as List))
    for (final g in (_map(p)['atomicGroups'] as List)) '${_map(g)['id']}',
};

void main() {
  test(
    'DCA real execution flows through candidate confirmation into holdings',
    () async {
      final client = DevApiClient(_baseUrl);
      final accounts = LocalServerAccountRepository(client);
      final dca = LocalServerDcaRepository(client);

      final funding = await accounts.createAccount(
        const CreateAccountInput(
          displayName: 'DCA 资金账户',
          accountType: AccountType.bank,
          defaultCurrency: 'CNY',
          balanceMode: 'cash_balance',
          openingBalance: Money(amount: '500.00', currency: 'CNY'),
        ),
      );
      final holding = await accounts.createAccount(
        const CreateAccountInput(
          displayName: 'DCA 持仓券商',
          accountType: AccountType.brokerage,
          defaultCurrency: 'CNY',
          balanceMode: 'holdings',
        ),
      );

      final plan = await dca.createPlan(
        CreateDcaPlanInput(
          displayName: 'UX 定投计划',
          targetInstrumentId: 'inst_ux_dca_fund',
          fundingAccountId: funding.id,
          plannedAmount: const Money(amount: '200.00', currency: 'CNY'),
          frequency: DcaFrequency.monthly,
          nextDueDate: '2026-07-01',
        ),
      );
      final reminder = (await dca.listDueReminders()).firstWhere(
        (item) => item.planId == plan.id,
      );

      final pendingBefore = _pendingGroupIds(
        await client.getData('/v1/ai/proposals/pending'),
      );

      // 投入 200、数量 10：计划金额只是成本默认值，绝不写进数量。
      await dca.markExecutedAsProposal(
        reminder.id,
        DcaExecutionInput(
          holdingAccountId: holding.id,
          quantity: '10',
          totalCost: const Money(amount: '200.00', currency: 'CNY'),
          quoteCurrency: 'CNY',
        ),
      );

      // 确认前：余额与持仓都不变。
      expect(
        _cashBalance(await client.getData('/v1/accounts/${funding.id}'), 'CNY'),
        '500.00',
      );
      expect(
        _holdingsOf(await client.getData('/v1/holdings'), holding.id),
        isEmpty,
      );

      final pendingAfter = _pendingGroupIds(
        await client.getData('/v1/ai/proposals/pending'),
      );
      final newGroups = pendingAfter.difference(pendingBefore);
      expect(newGroups, hasLength(1));

      // 用户确认后：扣资金、入持仓（quantity=10、costBasisTotal=200）。
      await client.postData('/v1/atomic-groups/${newGroups.single}/confirm');
      expect(
        _cashBalance(await client.getData('/v1/accounts/${funding.id}'), 'CNY'),
        '300.00',
      );
      final held = _holdingsOf(
        await client.getData('/v1/holdings'),
        holding.id,
      ).single;
      expect('${held['quantity']}', '10');
      expect('${_map(held['costBasisTotal'])['amount']}', '200.00');

      final dueAfter = await dca.listDueReminders();
      expect(dueAfter.map((item) => item.id), isNot(contains(reminder.id)));
    },
    skip: _baseUrl.isEmpty
        ? 'Set LOCAL_SERVER_API_BASE through --dart-define; run tools/frontend_local_server_smoke.ps1.'
        : false,
  );
}
