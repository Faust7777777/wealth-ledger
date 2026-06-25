// Smoke test: app boots into the real_local empty overview (no fixture, no DEMO).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finwealth/app/app.dart';

void main() {
  testWidgets('Boots to real_local empty overview', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: WealthLedgerApp()));
    await tester.pumpAndSettle();

    // 默认 real_local：空账本 → 概览空态 + 顶栏标题。
    expect(find.text('Wealth Ledger'), findsOneWidget);
    expect(find.text('今天开始记录你的净资产'), findsOneWidget);
  });
}
