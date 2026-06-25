// 纯 JSON→VM 映射测试：直接喂 docs/contracts/examples 的契约示例，无需起 dev server。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:finwealth/data/api_mock_repositories.dart';

Map<String, dynamic> _data(String path) {
  final body = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return (body['data'] as Map).cast<String, dynamic>();
}

void main() {
  test('parseOverviewData maps the degraded example payload', () {
    final vm = parseOverviewData(
      _data('docs/contracts/examples/portfolio_overview_degraded.response.json'),
    );
    expect(vm.latestSnapshot?.netWorth.amount, '245678.90');
    expect(vm.pendingSummary.aiPendingCount, 2);
    expect(vm.quoteStatusSummary.staleCount, 2);
    expect(vm.primaryHoldings.length, 1);
    expect(vm.primaryHoldings.first.symbol, 'NVDA');
    expect(vm.recentMovements.first.inTransit, isTrue);
    expect(vm.recentMovements.first.displayAmount?.amount, '500.00');
  });

  test('parseOverviewData maps the empty payload to an empty overview', () {
    final vm = parseOverviewData(
      _data('docs/contracts/examples/portfolio_overview_empty.response.json'),
    );
    expect(vm.isEmpty, isTrue);
  });
}
