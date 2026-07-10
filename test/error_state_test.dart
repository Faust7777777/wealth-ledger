// ErrorStateView 可行动引导：401 → 去登录；本地服务连不上 → 启动指引。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finwealth/shared/widgets.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('401 错误显示「需要登录」与去登录动作', (tester) async {
    await tester.pumpWidget(
      _host(
        ErrorStateView(
          message: '登录已失效或未登录（401）：请到「设置 → 本地服务登录」重新登录后重试（/v1/accounts）',
          onRetry: () {},
        ),
      ),
    );

    expect(find.text('需要登录'), findsOneWidget);
    expect(find.text('去登录'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('连接失败显示启动指引', (tester) async {
    await tester.pumpWidget(
      _host(
        ErrorStateView(
          message:
              'ClientException with SocketException: Connection refused, '
              'uri=http://127.0.0.1:8791/v1/portfolio/overview',
          onRetry: () {},
        ),
      ),
    );

    expect(find.text('无法连接本地服务'), findsOneWidget);
    expect(find.textContaining('run_self_use_windows.ps1'), findsOneWidget);
    expect(find.text('去登录'), findsNothing);
  });

  testWidgets('普通错误保持原样', (tester) async {
    await tester.pumpWidget(
      _host(ErrorStateView(message: 'HTTP 500 · /v1/accounts', onRetry: () {})),
    );

    expect(find.text('出错了'), findsOneWidget);
    expect(find.text('去登录'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
  });
}
