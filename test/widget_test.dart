// P0 smoke test: app boots and the token preview renders its hero + title.
import 'package:flutter_test/flutter_test.dart';
import 'package:finwealth/main.dart';

void main() {
  testWidgets('App boots and shows the token preview', (tester) async {
    await tester.pumpWidget(const WealthLedgerApp());
    await tester.pumpAndSettle();

    expect(find.text('P0 设计 token 预览'), findsOneWidget);
    expect(find.text('≈ ¥245,678.90'), findsOneWidget);
  });
}
