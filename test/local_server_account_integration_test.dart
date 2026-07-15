import 'package:finwealth/core/format.dart';
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _baseUrl = String.fromEnvironment('LOCAL_SERVER_API_BASE');

Map<String, dynamic> _map(Object? value) =>
    (value as Map).cast<String, dynamic>();

/// overview.latestSnapshot 的 (grossAssets, totalLiabilities, netWorth)；
/// 空账本尚无快照时按 0 处理。
Future<(String, String, String)> _totals(DevApiClient client) async {
  final overview = _map(await client.getData('/v1/portfolio/overview'));
  final snap = overview['latestSnapshot'];
  if (snap == null) return ('0', '0', '0');
  final s = _map(snap);
  return (
    '${_map(s['grossAssets'])['amount']}',
    '${_map(s['totalLiabilities'])['amount']}',
    '${_map(s['netWorth'])['amount']}',
  );
}

void main() {
  test(
    'opening balances and liability debt land in the real ledger and overview',
    () async {
      final client = DevApiClient(_baseUrl);
      final repo = LocalServerAccountRepository(client);
      final before = await _totals(client);

      // 期初余额 100.00 的银行账户（表单派生 balanceMode=cash_balance）。
      final bank = await repo.createAccount(
        const CreateAccountInput(
          displayName: 'UX 储蓄卡',
          accountType: AccountType.bank,
          defaultCurrency: 'CNY',
          balanceMode: 'cash_balance',
          openingBalance: Money(amount: '100.00', currency: 'CNY'),
        ),
      );
      expect(bank.isLiability, isFalse);
      expect(bank.cashBalances['CNY'], '100.00');

      // 当前欠款 2000.00 的信用卡（UI 正数输入 → 账本 -2000.00，
      // 表单派生 balanceMode=liability）。
      final card = await repo.createAccount(
        const CreateAccountInput(
          displayName: 'UX 信用卡',
          accountType: AccountType.creditCard,
          defaultCurrency: 'CNY',
          balanceMode: 'liability',
          openingBalance: Money(amount: '-2000.00', currency: 'CNY'),
        ),
      );
      expect(card.isLiability, isTrue);
      expect(card.cashBalances['CNY'], '-2000.00');

      // overview 核对（与账本内既有数据解耦，用前后差值）：
      // 总资产 +100，净资产 -1900，总负债变化幅度 2000。
      final after = await _totals(client);
      expect(subtractDecimal(after.$1, before.$1), '100.00');
      expect(subtractDecimal(after.$3, before.$3), '-1900.00');
      expect(absDecimal(subtractDecimal(after.$2, before.$2)), '2000.00');
    },
    skip: _baseUrl.isEmpty
        ? 'Set LOCAL_SERVER_API_BASE through --dart-define; run tools/frontend_local_server_smoke.ps1.'
        : false,
  );
}
