// Widget smoke tests for the record forms (manual / transfer / reconcile).
// 用 fake accounts override accountsProvider，验证三个录入页正常渲染（不触发写入）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/ai_import_csv_page.dart';
import 'package:finwealth/features/ai_import_image_page.dart';
import 'package:finwealth/features/dca_plan_form_page.dart';
import 'package:finwealth/features/manual_record_page.dart';
import 'package:finwealth/features/reconcile_page.dart';
import 'package:finwealth/features/taxonomy_page.dart';
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
  overrides: [
    accountsProvider.overrideWith((ref) async => accounts),
    categoriesProvider.overrideWith(
      (ref) async => const [
        CategoryVm(
          id: 'cat_coffee',
          displayName: '咖啡饮品',
          kind: CategoryKind.expense,
        ),
        CategoryVm(
          id: 'cat_salary',
          displayName: '工资收入',
          kind: CategoryKind.income,
        ),
      ],
    ),
    counterpartiesProvider.overrideWith(
      (ref) async => const [
        CounterpartyVm(
          id: 'cp_luckin',
          displayName: '瑞幸咖啡',
          aliases: ['瑞幸'],
          categoryHintId: 'cat_coffee',
        ),
        CounterpartyVm(
          id: 'cp_luckin_short',
          displayName: '瑞幸',
          categoryHintId: 'cat_coffee',
        ),
      ],
    ),
  ],
  child: MaterialApp(home: page),
);

void main() {
  testWidgets('ManualRecordPage renders form with accounts', (t) async {
    await t.pumpWidget(_host(const ManualRecordPage(), [_acct('a1', '钱包')]));
    await t.pumpAndSettle();
    expect(find.text('支出'), findsOneWidget);
    expect(find.text('收入'), findsOneWidget);
    expect(find.text('钱包'), findsWidgets);
    expect(find.text('分类（可选）'), findsOneWidget);
    expect(find.text('对手方（可选）'), findsOneWidget);
    await t.drag(find.byType(ListView), const Offset(0, -500));
    await t.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '记一笔'), findsOneWidget);
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

  testWidgets('DcaPlanFormPage renders with funding account', (t) async {
    await t.pumpWidget(_host(const DcaPlanFormPage(), [_acct('a1', '钱包')]));
    await t.pumpAndSettle();
    expect(find.text('计划名称'), findsOneWidget);
    expect(find.text('投资目标'), findsOneWidget);
    expect(find.text('资金账户'), findsOneWidget);
    expect(find.text('每期金额'), findsOneWidget);
    await t.drag(find.byType(ListView), const Offset(0, -700));
    await t.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '创建定投计划'), findsOneWidget);
  });

  testWidgets('TaxonomyPage renders categories and counterparties', (t) async {
    await t.pumpWidget(_host(const TaxonomyPage(), const []));
    await t.pumpAndSettle();
    expect(find.text('分类'), findsOneWidget);
    expect(find.text('新增分类'), findsOneWidget);
    expect(find.text('咖啡饮品'), findsWidgets);
    await t.dragUntilVisible(
      find.text('新增对手方'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    await t.pumpAndSettle();
    expect(find.text('新增对手方'), findsOneWidget);
    expect(find.text('合并对手方'), findsOneWidget);
    expect(find.text('瑞幸咖啡'), findsWidgets);
  });
}
