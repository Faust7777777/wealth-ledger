// 动画原语行为锁定：Reveal 最终呈现子节点、尊重减弱动态效果；
// AnimatedMoneyText 呈现当前值并能过渡到新值（不伪造中间数字）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finwealth/shared/widgets.dart';

Widget _host(Widget child, {bool reduceMotion = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(body: child),
  ),
);

void main() {
  testWidgets('Reveal 动画结束后完全呈现子节点', (tester) async {
    await tester.pumpWidget(_host(const Reveal(child: Text('净资产'))));
    // 入场途中已在树内（透明度渐变），结束后不透明。
    await tester.pumpAndSettle();
    expect(find.text('净资产'), findsOneWidget);
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: find.text('净资产'), matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, 1.0);
  });

  testWidgets('减弱动态效果时 Reveal 直接呈现、无 Opacity 包裹', (tester) async {
    await tester.pumpWidget(
      _host(const Reveal(child: Text('净资产')), reduceMotion: true),
    );
    await tester.pump();
    expect(find.text('净资产'), findsOneWidget);
    expect(
      find.ancestor(of: find.text('净资产'), matching: find.byType(Opacity)),
      findsNothing,
    );
  });

  testWidgets('AnimatedMoneyText 呈现当前值并过渡到新值', (tester) async {
    await tester.pumpWidget(_host(const AnimatedMoneyText('¥100')));
    await tester.pumpAndSettle();
    expect(find.text('¥100'), findsOneWidget);

    await tester.pumpWidget(_host(const AnimatedMoneyText('¥200')));
    await tester.pump(); // 过渡开始：新旧值可能同时在树内
    await tester.pumpAndSettle();
    expect(find.text('¥200'), findsOneWidget);
    expect(find.text('¥100'), findsNothing);
  });
}
