// 账户创建与负债展示可用性回归
// （C:/tmp/2026-07-15-claude-account-liability-ux-handoff.md §8 的 12 项 + 零值固定行为）。
import 'dart:convert';

import 'package:finwealth/app/app.dart';
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/account_form_page.dart';
import 'package:finwealth/features/account_type_picker.dart';
import 'package:finwealth/features/liabilities_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _caps = LedgerCapabilitiesVm(
  dataSourceMode: 'local_server',
  canWriteConfirmedLedger: true,
  canCreateAccount: true,
  canRecordMovement: true,
  canConfirmProposal: true,
  canPersistPendingProposal: true,
  proposalPersistence: 'file',
);

AccountVm _liability(String amount) => AccountVm(
  id: 'acct_cc',
  displayName: '招行信用卡',
  accountType: AccountType.creditCard,
  isLiability: true,
  value: ValuedMoney(
    amount: amount,
    currency: 'CNY',
    asOf: '2026-07-15T09:00:00+08:00',
    quality: ValueQuality.exact,
  ),
);

/// 捕获真实 HTTP 映射：LocalServerAccountRepository + MockClient。
({AccountRepository repo, List<http.Request> requests}) _capturingRepo() {
  final requests = <http.Request>[];
  final client = DevApiClient(
    'http://127.0.0.1:1',
    client: MockClient((req) async {
      requests.add(req);
      return http.Response(
        jsonEncode({
          'ok': true,
          'data': {
            'id': 'a1',
            'displayName': '测试账户',
            'accountType': 'bank',
            'defaultCurrency': 'CNY',
            'balanceMode': 'cash_balance',
            'includeInNetWorth': true,
          },
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
  return (repo: LocalServerAccountRepository(client), requests: requests);
}

/// 表单需要 GoRouter（保存后 pop）：挂成 '/' 的子路由。
Widget _routedForm(Widget form, {required AccountRepository repo}) {
  final router = GoRouter(
    initialLocation: '/form',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(),
        routes: [GoRoute(path: 'form', builder: (_, _) => form)],
      ),
    ],
  );
  return ProviderScope(
    overrides: [accountRepositoryProvider.overrideWithValue(repo)],
    child: MaterialApp.router(routerConfig: router),
  );
}

Future<void> _fillName(WidgetTester tester) async {
  await tester.enterText(find.widgetWithText(TextField, '账户名称'), '测试账户');
  await tester.pump();
}

Future<void> _pickTypeInDialog(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(kAccountTypeFieldKey));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.ensureVisible(find.text('创建账户'));
  await tester.tap(find.text('创建账户'));
  await tester.pumpAndSettle();
}

Map<String, dynamic> _bodyOf(http.Request req) =>
    jsonDecode(req.body) as Map<String, dynamic>;

void main() {
  group('负债页展示语义', () {
    Widget host(List<AccountVm> items) => ProviderScope(
      overrides: [
        capabilitiesProvider.overrideWith((ref) async => _caps),
        liabilitiesProvider.overrideWith((ref) async => items),
      ],
      child: const MaterialApp(home: Scaffold(body: LiabilitiesPage())),
    );

    testWidgets('1. 空态无「负债余额为负」解释，标题/按钮为新文案', (tester) async {
      await tester.pumpWidget(host(const []));
      await tester.pumpAndSettle();
      expect(find.textContaining('负债余额为负'), findsNothing);
      expect(find.textContaining('是正常的'), findsNothing);
      expect(find.text('暂无负债账户'), findsOneWidget);
      expect(find.text('添加信用卡或贷款'), findsOneWidget);
    });

    testWidgets('10. 账本 -2000.00 显示 2,000.00 且无负号', (tester) async {
      await tester.pumpWidget(host([_liability('-2000.00')]));
      await tester.pumpAndSettle();
      expect(find.text('¥2,000.00'), findsOneWidget);
      expect(find.textContaining('-2,000'), findsNothing);
      expect(find.textContaining('-¥'), findsNothing);
      expect(find.text('当前欠款'), findsOneWidget);
    });

    testWidgets('10b. 账本 0.00 显示已还清', (tester) async {
      await tester.pumpWidget(host([_liability('0.00')]));
      await tester.pumpAndSettle();
      expect(find.text('已还清'), findsOneWidget);
      expect(find.text('当前欠款'), findsNothing);
    });

    testWidgets('11. 信用卡正余额显示溢缴款，不显示成欠款', (tester) async {
      await tester.pumpWidget(host([_liability('500.00')]));
      await tester.pumpAndSettle();
      expect(find.text('¥500.00'), findsOneWidget);
      expect(find.text('溢缴款'), findsOneWidget);
      expect(find.text('当前欠款'), findsNothing);
    });
  });

  group('账户类型选择器', () {
    testWidgets('3. 分组与新名称齐全，11 个类型都可选', (tester) async {
      final h = _capturingRepo();
      await tester.pumpWidget(
        _routedForm(const AccountFormPage(), repo: h.repo),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccountTypeFieldKey));
      await tester.pumpAndSettle();
      for (final group in ['日常资金', '投资资产', '负债', '其他']) {
        await tester.ensureVisible(find.text(group));
        expect(find.text(group), findsOneWidget);
      }
      const labels = [
        '银行账户',
        '现金',
        '支付平台余额',
        '虚拟卡/预付卡',
        '证券账户',
        '数字资产交易所',
        '数字资产钱包',
        '社保/养老金',
        '信用卡',
        '贷款',
        '其他账户',
      ];
      for (final label in labels) {
        await tester.ensureVisible(find.text(label).last);
        expect(find.text(label), findsWidgets);
      }
      // 不暴露内部概念。
      expect(find.textContaining('余额模式'), findsNothing);
      expect(find.textContaining('balanceMode'), findsNothing);
      // 选中一个非默认类型，字段随之更新。
      await tester.ensureVisible(find.text('数字资产交易所'));
      await tester.tap(find.text('数字资产交易所'));
      await tester.pumpAndSettle();
      expect(find.textContaining('数字资产交易所 · 加密货币交易所'), findsOneWidget);
    });

    testWidgets('12. 1200×800 与 1440×900 下选择器受限、不占整屏', (tester) async {
      final h = _capturingRepo();
      for (final size in const [Size(1200, 800), Size(1440, 900)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _routedForm(const AccountFormPage(), repo: h.repo),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(kAccountTypeFieldKey));
        await tester.pumpAndSettle();
        // 量对话框表面（第一个 Material）：外层 widget 渲染盒是全屏约束盒。
        final surface = find
            .descendant(
              of: find.byType(AccountTypePickerDialog),
              matching: find.byType(Material),
            )
            .first;
        final dialogSize = tester.getSize(surface);
        expect(dialogSize.width, lessThanOrEqualTo(480));
        expect(dialogSize.height, lessThanOrEqualTo(size.height * 0.75));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
    });
  });

  group('余额模式自动派生 + 期初余额映射（真实 POST/PATCH 捕获）', () {
    testWidgets('4+7. 信用卡：balanceMode=liability，欠款 2000.00 → -2000.00', (
      tester,
    ) async {
      final h = _capturingRepo();
      await tester.pumpWidget(
        _routedForm(const AccountFormPage(), repo: h.repo),
      );
      await tester.pumpAndSettle();
      await _fillName(tester);
      await _pickTypeInDialog(tester, '信用卡');
      expect(find.text('当前欠款（可选）'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, '当前欠款（可选）'),
        '2000.00',
      );
      await _save(tester);
      final body = _bodyOf(h.requests.single);
      expect(h.requests.single.method, 'POST');
      expect(body['balanceMode'], 'liability');
      expect(body['openingBalances'], [
        {'currency': 'CNY', 'amount': '-2000.00', 'quality': 'exact'},
      ]);
    });

    testWidgets('5. 贷款：balanceMode=liability', (tester) async {
      final h = _capturingRepo();
      await tester.pumpWidget(
        _routedForm(const AccountFormPage(), repo: h.repo),
      );
      await tester.pumpAndSettle();
      await _fillName(tester);
      await _pickTypeInDialog(tester, '贷款');
      await _save(tester);
      expect(_bodyOf(h.requests.single)['balanceMode'], 'liability');
    });

    testWidgets('6+8. 银行账户：balanceMode=cash_balance，期初 100.00 原样发送', (
      tester,
    ) async {
      final h = _capturingRepo();
      await tester.pumpWidget(
        _routedForm(const AccountFormPage(), repo: h.repo),
      );
      await tester.pumpAndSettle();
      await _fillName(tester);
      expect(find.text('期初余额（可选）'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, '期初余额（可选）'),
        '100.00',
      );
      await _save(tester);
      final body = _bodyOf(h.requests.single);
      expect(body['balanceMode'], 'cash_balance');
      expect(body['openingBalances'], [
        {'currency': 'CNY', 'amount': '100.00', 'quality': 'exact'},
      ]);
    });

    testWidgets('7b. 欠款输入 0 → 固定发送空 openingBalances', (tester) async {
      final h = _capturingRepo();
      await tester.pumpWidget(
        _routedForm(const AccountFormPage(), repo: h.repo),
      );
      await tester.pumpAndSettle();
      await _fillName(tester);
      await _pickTypeInDialog(tester, '信用卡');
      await tester.enterText(find.widgetWithText(TextField, '当前欠款（可选）'), '0');
      await _save(tester);
      expect(_bodyOf(h.requests.single)['openingBalances'], isEmpty);
    });

    testWidgets('9. 编辑 mixed 账户且不改类型：保留 mixed，且不发送期初余额', (tester) async {
      final h = _capturingRepo();
      const existing = AccountVm(
        id: 'a9',
        displayName: '历史混合账户',
        accountType: AccountType.bank,
        isLiability: false,
        balanceMode: 'mixed',
      );
      await tester.pumpWidget(
        _routedForm(const AccountFormPage(existing: existing), repo: h.repo),
      );
      await tester.pumpAndSettle();
      // 编辑模式不出现期初余额/当前欠款字段。
      expect(find.textContaining('期初余额'), findsNothing);
      expect(find.textContaining('当前欠款'), findsNothing);
      await tester.ensureVisible(find.text('保存修改'));
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      final req = h.requests.single;
      expect(req.method, 'PATCH');
      final body = _bodyOf(req);
      expect(body['balanceMode'], 'mixed');
      expect(body.containsKey('openingBalances'), isFalse);
    });
  });

  group('负债页入口默认信用卡（全应用路由）', () {
    testWidgets('2. 空态按钮 → 新建页默认信用卡与「当前欠款」', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            capabilitiesProvider.overrideWith((ref) async => _caps),
            liabilitiesProvider.overrideWith((ref) async => const []),
          ],
          child: const WealthLedgerApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('负债'));
      await tester.pumpAndSettle();
      expect(find.text('暂无负债账户'), findsOneWidget);
      await tester.tap(find.text('添加信用卡或贷款'));
      await tester.pumpAndSettle();
      expect(find.text('新建账户'), findsOneWidget);
      expect(find.textContaining('信用卡 · 信用卡当前欠款'), findsOneWidget);
      expect(find.text('当前欠款（可选）'), findsOneWidget);
    });
  });
}
