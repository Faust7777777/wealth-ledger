// 纯 JSON→VM 映射测试：直接喂 docs/contracts/examples 的契约示例，无需起 dev server。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:finwealth/core/format.dart';
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
    expect(vm.changeSinceLastSnapshot?.amount, '1245.67'); // 245678.90 - 244433.23
  });

  test('parseOverviewData maps the empty payload to an empty overview', () {
    final vm = parseOverviewData(
      _data('docs/contracts/examples/portfolio_overview_empty.response.json'),
    );
    expect(vm.isEmpty, isTrue);
  });

  test('parseAssetAllocationData maps server allocation payload', () {
    final vm = parseAssetAllocationData({
      'slices': [
        {
          'category': '现金',
          'percent': '100.0',
          'value': {'amount': '123.45', 'currency': 'CNY'},
        }
      ],
      'totalAssets': {'amount': '123.45', 'currency': 'CNY'},
      'totalLiabilities': {'amount': '20.00', 'currency': 'CNY'},
      'netWorth': {'amount': '103.45', 'currency': 'CNY'},
    });

    expect(vm.slices.length, 1);
    expect(vm.slices.first.category, '现金');
    expect(vm.slices.first.percent, '100.0');
    expect(vm.totalAssets.amount, '123.45');
    expect(vm.totalLiabilities.amount, '20.00');
    expect(vm.netWorth.amount, '103.45');
  });

  test('subtractDecimal does exact decimal subtraction (no double)', () {
    expect(subtractDecimal('245678.90', '244433.23'), '1245.67');
    expect(subtractDecimal('100', '100.50'), '-0.50');
    expect(subtractDecimal('5', '3'), '2');
    expect(subtractDecimal('0.10', '0.30'), '-0.20');
  });
}
