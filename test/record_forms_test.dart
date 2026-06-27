// Widget smoke tests for the record forms (manual / transfer / reconcile).
// 用 fake accounts override accountsProvider，验证三个录入页正常渲染（不触发写入）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/ai_import_csv_page.dart';
import 'package:finwealth/features/ai_import_image_page.dart';
import 'package:finwealth/features/manual_record_page.dart';
import 'package:finwealth/features/reconcile_page.dart';
import 'package:finwealth/features/transfer_page.dart';

AccountVm _acct(
  String id,
  String name, {
  String cur = 'CNY',
  Map<String, String> cash = const {},
}) => AccountVm(
  id: id,
  displayName: name,
  accountType: AccountType.bank,
  isLiability: false,
  defaultCurrency: cur,
  cashBalances: cash,
);

Widget _host(Widget page, List<AccountVm> accounts) => ProviderScope(
  overrides: [accountsProvider.overrideWith((ref) async => accounts)],
  child: MaterialApp(home: page),
);

void main() {
  testWidgets('ManualRecordPage renders form with accounts', (t) async {
    await t.pumpWidget(_host(const ManualRecordPage(), [_acct('a1', '钱包')]));
    await t.pumpAndSettle();
    expect(find.text('支出'), findsOneWidget);
    expect(find.text('收入'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '记一笔'), findsOneWidget);
    expect(find.text('钱包'), findsWidgets);
  });

  testWidgets('TransferPage renders with two accounts', (t) async {
    await t.pumpWidget(
      _host(const TransferPage(), [_acct('a1', '钱包'), _acct('a2', '储蓄')]),
    );
    await t.pumpAndSettle();
    expect(find.text('转出账户'), findsOneWidget);
    expect(find.text('转入账户'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '转账'), findsOneWidget);
  });

  testWidgets('TransferPage requires two accounts', (t) async {
    await t.pumpWidget(_host(const TransferPage(), [_acct('a1', '钱包')]));
    await t.pumpAndSettle();
    expect(find.text('至少需要两个账户'), findsOneWidget);
  });

  testWidgets('ReconcilePage shows current balance', (t) async {
    await t.pumpWidget(
      _host(const ReconcilePage(), [
        _acct('a1', '钱包', cash: {'CNY': '1000.00'}),
      ]),
    );
    await t.pumpAndSettle();
    expect(find.text('当前记录余额'), findsOneWidget);
    expect(find.textContaining('1,000.00'), findsWidgets);
  });

  testWidgets('AiImportCsvPage renders with default account', (t) async {
    await t.pumpWidget(_host(const AiImportCsvPage(), [_acct('a1', '钱包')]));
    await t.pumpAndSettle();
    expect(find.text('默认账户'), findsOneWidget);
    expect(find.textContaining('钱包'), findsWidgets);
    expect(find.text('CSV 内容'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '生成候选'), findsOneWidget);
  });

  testWidgets('AiImportImagePage renders base64 form', (t) async {
    await t.pumpWidget(_host(const AiImportImagePage(), const []));
    await t.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, '选择图片'), findsOneWidget);
    expect(find.text('图片文件名'), findsOneWidget);
    expect(find.text('图片 Base64 / data URL（可选兜底）'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '生成候选'), findsOneWidget);
  });
}
