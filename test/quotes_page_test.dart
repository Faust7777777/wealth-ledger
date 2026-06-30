// Widget smoke test for QuotesPage: override quotes/fxRates providers with fakes,
// 验证行情/汇率列表与录入入口正常渲染（不触发写入）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/quotes_page.dart';

void main() {
  testWidgets('QuotesPage renders quotes + fx with entry actions', (t) async {
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          quotesProvider.overrideWith(
            (ref) async => const [
              QuoteVm(
                id: 'q1',
                instrumentId: 'NVDA',
                price: '142.50',
                currency: 'USD',
                asOf: '2026-06-28T09:00:00+08:00',
                status: QuoteStatus.stale,
                source: 'manual',
              ),
            ],
          ),
          fxRatesProvider.overrideWith(
            (ref) async => const [
              FxRateVm(
                id: 'fx1',
                baseCurrency: 'USD',
                quoteCurrency: 'CNY',
                rate: '7.12',
                asOf: '2026-06-28T09:00:00+08:00',
                status: QuoteStatus.fresh,
                source: 'manual',
              ),
            ],
          ),
        ],
        child: const MaterialApp(home: QuotesPage()),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('行情'), findsOneWidget);
    expect(find.text('汇率'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '录入行情'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '录入汇率'), findsOneWidget);
    expect(find.text('NVDA'), findsOneWidget);
    expect(find.text('USD → CNY'), findsOneWidget);
    expect(find.textContaining('过期'), findsWidgets);
  });

  testWidgets('QuotesPage shows empty hints when no data', (t) async {
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          quotesProvider.overrideWith((ref) async => const <QuoteVm>[]),
          fxRatesProvider.overrideWith((ref) async => const <FxRateVm>[]),
        ],
        child: const MaterialApp(home: QuotesPage()),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('暂无行情'), findsOneWidget);
    expect(find.textContaining('暂无汇率'), findsOneWidget);
  });
}
