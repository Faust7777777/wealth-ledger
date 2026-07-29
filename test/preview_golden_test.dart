// 视觉预览（非回归断言）：用真实主题 + 真实 Noto Sans/Serif SC 字体把关键页渲成 PNG，
// 供人肉眼/模型核验子主题、字体、间距、动效入场后的静态形态。
// 生成：PREVIEW_GOLDENS=1 flutter test --update-goldens test/preview_golden_test.dart
// 默认在普通 `flutter test` 中跳过（golden 依赖字体/Skia，跨机不稳，不做门禁）。
import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finwealth/app/app.dart';
import 'package:finwealth/core/env.dart';
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/accounts_page.dart';
import 'package:finwealth/features/ai_review_page.dart';
import 'package:finwealth/features/account_form_page.dart';
import 'package:finwealth/features/account_type_picker.dart';
import 'package:finwealth/features/dca_execution_dialog.dart';
import 'package:finwealth/data/api_mock_repositories.dart'
    show
        ApiServiceUnavailableException,
        ApiUnauthorizedException,
        parseAiProposalData,
        parseLiabilityPositionData,
        parseMovementData;
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/features/investment_page.dart';
import 'package:finwealth/features/investment_trade_page.dart';
import 'package:finwealth/features/movement_detail_page.dart';
import 'package:finwealth/features/account_detail_page.dart';
import 'package:finwealth/features/subscription_form_page.dart';
import 'package:finwealth/features/valuation_status_sheet.dart';
import 'package:finwealth/features/liability_terms_page.dart';
import 'package:finwealth/features/loan_section.dart';
import 'package:finwealth/features/agent_automations_page.dart';
import 'package:finwealth/features/agent_panel.dart';
import 'package:finwealth/features/ai_import_text_page.dart';
import 'package:finwealth/features/liabilities_page.dart';
import 'package:finwealth/features/manual_record_page.dart';
import 'package:finwealth/features/overview_page.dart';
import 'package:finwealth/features/subscription_detail_page.dart';
import 'package:finwealth/features/subscriptions_page.dart';
import 'package:finwealth/theme/app_theme.dart';

Future<void> _loadFonts() async {
  final bytes = File('assets/fonts/NotoSansSC-400.ttf').readAsBytesSync();
  ByteData toData() => ByteData.view(Uint8List.fromList(bytes).buffer);
  // 应用 family 首选 Inter（未打包）→ 回退 NotoSansSC；两个 family 都注册成正文体字形，
  // 保证 golden 里所有文字都实打实渲染。
  for (final family in ['NotoSansSC', 'Inter']) {
    final loader = FontLoader(family)..addFont(Future.value(toData()));
    await loader.load();
  }
  // 衬线（Hero=700 / 标题=500）：两个字重都注册到同一 family，按字重匹配。
  final serifLoader = FontLoader('NotoSerifSC');
  for (final w in ['500', '700']) {
    final b = File('assets/fonts/NotoSerifSC-$w.ttf').readAsBytesSync();
    serifLoader.addFont(
      Future.value(ByteData.view(Uint8List.fromList(b).buffer)),
    );
  }
  await serifLoader.load();
  await _loadMaterialIcons();
}

// 加载 MaterialIcons 让 golden 里的图标真实渲染（否则显示为方块）。找不到则跳过。
Future<void> _loadMaterialIcons() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  final candidates = [
    if (root != null)
      '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    r'C:\Users\15892\scoop\apps\flutter\3.44.4\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) {
      final data = ByteData.view(
        Uint8List.fromList(file.readAsBytesSync()).buffer,
      );
      await (FontLoader('MaterialIcons')..addFont(Future.value(data))).load();
      return;
    }
  }
}

Future<void> _settleEntrance(WidgetTester tester) async {
  // 固定推进而非 pumpAndSettle：跨过 Reveal(380ms)/money 切换(420ms) 等入场，
  // 又不因任何重复动画卡死。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  // 对话列表首帧后还会排一次滚动到底（延时 + 有限动画），多推进两拍收尾。
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

// 仅当 PREVIEW_GOLDENS=1 时运行，避免机器相关的 golden 进入常规测试门禁。
final bool _previewEnabled = Platform.environment['PREVIEW_GOLDENS'] == '1';

void main() {
  setUpAll(_loadFonts);

  Future<void> sized(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('overview dark · phone', skip: !_previewEnabled, (tester) async {
    await sized(tester, const Size(400, 880));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appEnvironmentProvider.overrideWithValue(
            const AppEnvironment(dataSourceMode: DataSourceMode.debugFixture),
          ),
        ],
        child: const WealthLedgerApp(),
      ),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(WealthLedgerApp),
      matchesGoldenFile('goldens/overview_dark_phone.png'),
    );
  });

  // 空态（real_local 默认空账本）：看首屏品牌插画落在暗底上的效果。
  testWidgets('overview empty · phone', skip: !_previewEnabled, (tester) async {
    await sized(tester, const Size(400, 880));
    await tester.pumpWidget(const ProviderScope(child: WealthLedgerApp()));
    await _settleEntrance(tester);
    // Image.asset 异步解码；先在 runAsync 里预热到 image cache，再 pump 才能画出来。
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage('assets/illustrations/net-worth-empty-state.png'),
        tester.element(find.byType(WealthLedgerApp)),
      );
    });
    await tester.pump();
    await expectLater(
      find.byType(WealthLedgerApp),
      matchesGoldenFile('goldens/overview_empty_phone.png'),
    );
  });

  testWidgets('overview dark · desktop (rail)', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(1440, 900));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appEnvironmentProvider.overrideWithValue(
            const AppEnvironment(dataSourceMode: DataSourceMode.debugFixture),
          ),
        ],
        child: const WealthLedgerApp(),
      ),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(WealthLedgerApp),
      matchesGoldenFile('goldens/overview_dark_desktop.png'),
    );
  });

  // 浅色主题的概览内容（页面直 pump + 浅色主题）：核验整套子主题在 light 下不漏暗色。
  testWidgets('overview content · light', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 1100));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appEnvironmentProvider.overrideWithValue(
            const AppEnvironment(dataSourceMode: DataSourceMode.debugFixture),
          ),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const Scaffold(body: OverviewPage()),
        ),
      ),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(OverviewPage),
      matchesGoldenFile('goldens/overview_light.png'),
    );
  });

  // 投资空态（real_local 默认空）：核验第二枚品牌插画（同心弧+圆）落在暗底上的效果。
  testWidgets('investment empty · dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 880));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: const Scaffold(body: InvestmentPage()),
        ),
      ),
    );
    await _settleEntrance(tester);
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage('assets/illustrations/investment-empty-state.png'),
        tester.element(find.byType(InvestmentPage)),
      );
    });
    await tester.pump();
    await expectLater(
      find.byType(InvestmentPage),
      matchesGoldenFile('goldens/investment_empty.png'),
    );
  });

  // AI 复核页（fixture 提案）：核验语义色操作胶囊 + 逐组子面板 + old→new diff。
  testWidgets('ai review · dark', skip: !_previewEnabled, (tester) async {
    await sized(tester, const Size(400, 940));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appEnvironmentProvider.overrideWithValue(
            const AppEnvironment(dataSourceMode: DataSourceMode.debugFixture),
          ),
        ],
        child: MaterialApp(theme: buildDarkTheme(), home: const AiReviewPage()),
      ),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(AiReviewPage),
      matchesGoldenFile('goldens/ai_review_dark.png'),
    );
  });

  // 账户列表（fixture）：核验 LeadingAvatar 类型图标徽标落在行首的效果。
  testWidgets('accounts list · dark', skip: !_previewEnabled, (tester) async {
    await sized(tester, const Size(400, 900));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appEnvironmentProvider.overrideWithValue(
            const AppEnvironment(dataSourceMode: DataSourceMode.debugFixture),
          ),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: const Scaffold(body: AccountsPage()),
        ),
      ),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(AccountsPage),
      matchesGoldenFile('goldens/accounts_dark.png'),
    );
  });

  // 表单页直接 pump（避开整 app 启动逻辑），展示输入/按钮/分段控件的子主题。
  Widget formHost(ThemeData theme) => ProviderScope(
    overrides: [
      appEnvironmentProvider.overrideWithValue(
        const AppEnvironment(dataSourceMode: DataSourceMode.debugFixture),
      ),
      accountsProvider.overrideWith(
        (ref) async => const [
          AccountVm(
            id: 'a1',
            displayName: '招商银行',
            accountType: AccountType.bank,
            isLiability: false,
            defaultCurrency: 'CNY',
            cashBalances: {'CNY': '12800.00'},
          ),
        ],
      ),
      categoriesProvider.overrideWith(
        (ref) async => const [
          CategoryVm(id: 'c1', displayName: '餐饮', kind: CategoryKind.expense),
        ],
      ),
      counterpartiesProvider.overrideWith(
        (ref) async => const <CounterpartyVm>[],
      ),
    ],
    child: MaterialApp(theme: theme, home: const ManualRecordPage()),
  );

  testWidgets('manual record form · dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 880));
    await tester.pumpWidget(formHost(buildDarkTheme()));
    await _settleEntrance(tester);
    await expectLater(
      find.byType(ManualRecordPage),
      matchesGoldenFile('goldens/form_dark.png'),
    );
  });

  testWidgets('manual record form · light', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 880));
    await tester.pumpWidget(formHost(buildLightTheme()));
    await _settleEntrance(tester);
    await expectLater(
      find.byType(ManualRecordPage),
      matchesGoldenFile('goldens/form_light.png'),
    );
  });

  // —— 订阅管理预览 ——
  const gptSub = SubscriptionVm(
    id: 'sub_gpt',
    displayName: 'ChatGPT Plus',
    provider: 'OpenAI',
    planName: 'Plus',
    amount: Money(amount: '20.00', currency: 'USD'),
    paymentAccountId: 'a1',
    billingCycle: SubscriptionBillingCycleVm(
      unit: BillingUnit.month,
      interval: 1,
    ),
    billingAnchorDay: 5,
    startDate: '2026-01-05',
    nextChargeDate: '2026-08-05',
    autoRenew: true,
    reminderDaysBefore: 3,
    status: SubscriptionStatus.active,
  );
  const claudeSub = SubscriptionVm(
    id: 'sub_claude',
    displayName: 'Claude Pro',
    provider: 'Anthropic',
    planName: 'Pro',
    amount: Money(amount: '20.00', currency: 'USD'),
    paymentAccountId: 'a1',
    billingCycle: SubscriptionBillingCycleVm(
      unit: BillingUnit.month,
      interval: 1,
    ),
    billingAnchorDay: 12,
    startDate: '2026-03-12',
    nextChargeDate: '2026-07-12',
    autoRenew: true,
    reminderDaysBefore: 3,
    status: SubscriptionStatus.active,
    pendingChargeMovementId: 'mov_pending',
    pendingChargeDate: '2026-07-12',
  );
  const subAccount = AccountVm(
    id: 'a1',
    displayName: '美股券商',
    accountType: AccountType.brokerage,
    isLiability: false,
    defaultCurrency: 'USD',
  );

  Widget subsHost(ThemeData theme, Widget page) => ProviderScope(
    overrides: [
      capabilitiesProvider.overrideWith(
        (ref) async => const LedgerCapabilitiesVm(
          dataSourceMode: 'local_server',
          canWriteConfirmedLedger: true,
          canCreateAccount: true,
          canRecordMovement: true,
          canConfirmProposal: true,
          canPersistPendingProposal: true,
          proposalPersistence: 'file',
          canManageSubscriptions: true,
        ),
      ),
      accountsProvider.overrideWith((ref) async => const [subAccount]),
      subscriptionsProvider.overrideWith(
        (ref) async => const [gptSub, claudeSub],
      ),
      upcomingSubscriptionsProvider.overrideWith(
        (ref) async => const [claudeSub],
      ),
      subscriptionByIdProvider(
        'sub_claude',
      ).overrideWith((ref) async => claudeSub),
    ],
    child: MaterialApp(theme: theme, home: page),
  );

  testWidgets('subscriptions list · dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 900));
    await tester.pumpWidget(
      subsHost(buildDarkTheme(), const SubscriptionsPage()),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(SubscriptionsPage),
      matchesGoldenFile('goldens/subscriptions_dark.png'),
    );
  });

  testWidgets('subscriptions list · light', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 900));
    await tester.pumpWidget(
      subsHost(buildLightTheme(), const SubscriptionsPage()),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(SubscriptionsPage),
      matchesGoldenFile('goldens/subscriptions_light.png'),
    );
  });

  testWidgets('subscription detail · dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 1000));
    await tester.pumpWidget(
      subsHost(
        buildDarkTheme(),
        const SubscriptionDetailPage(subscriptionId: 'sub_claude'),
      ),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(SubscriptionDetailPage),
      matchesGoldenFile('goldens/subscription_detail_dark.png'),
    );
  });

  // —— 到期扫描结果对话框（created/already-pending/blocked/hasMore 全区段）——
  const dueScanResult = SubscriptionDueScanResultVm(
    throughDate: '2026-07-13',
    createdCount: 2,
    alreadyPendingCount: 1,
    blockedCount: 1,
    remainingEligibleCount: 3,
    hasMore: true,
    skipped: [
      SubscriptionDueScanSkipVm(
        subscriptionId: 'sub_claude',
        scheduledChargeDate: '2026-07-12',
        reason: SubscriptionDueScanSkipReason.alreadyPending,
      ),
      SubscriptionDueScanSkipVm(
        subscriptionId: 'sub_gpt',
        scheduledChargeDate: '2026-07-05',
        reason: SubscriptionDueScanSkipReason.paymentAccountUnavailable,
      ),
    ],
  );
  const dueScanNames = {'sub_gpt': 'ChatGPT Plus', 'sub_claude': 'Claude Pro'};

  Widget dueScanHost(ThemeData theme) => subsHost(
    theme,
    const Scaffold(
      body: Center(
        child: DueScanResultDialog(
          result: dueScanResult,
          subscriptionNames: dueScanNames,
        ),
      ),
    ),
  );

  testWidgets('subscription due-scan dialog · dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 760));
    await tester.pumpWidget(dueScanHost(buildDarkTheme()));
    await _settleEntrance(tester);
    await expectLater(
      find.byType(DueScanResultDialog),
      matchesGoldenFile('goldens/subscription_due_scan_dialog_dark.png'),
    );
  });

  testWidgets('subscription due-scan dialog · light', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 760));
    await tester.pumpWidget(dueScanHost(buildLightTheme()));
    await _settleEntrance(tester);
    await expectLater(
      find.byType(DueScanResultDialog),
      matchesGoldenFile('goldens/subscription_due_scan_dialog_light.png'),
    );
  });

  // —— 负债展示语义 + 账户表单/类型选择器（2026-07-15 账户可用性批）——
  AccountVm liab(String id, String name, String amount) => AccountVm(
    id: id,
    displayName: name,
    accountType: id.contains('loan')
        ? AccountType.loan
        : AccountType.creditCard,
    isLiability: true,
    value: ValuedMoney(
      amount: amount,
      currency: 'CNY',
      asOf: '2026-07-15T09:00:00+08:00',
      quality: ValueQuality.exact,
    ),
  );

  Widget liabHost(ThemeData theme, Widget page, List<AccountVm> items) =>
      ProviderScope(
        overrides: [
          capabilitiesProvider.overrideWith(
            (ref) async => const LedgerCapabilitiesVm(
              dataSourceMode: 'local_server',
              canWriteConfirmedLedger: true,
              canCreateAccount: true,
              canRecordMovement: true,
              canConfirmProposal: true,
              canPersistPendingProposal: true,
              proposalPersistence: 'file',
            ),
          ),
          liabilitiesProvider.overrideWith((ref) async => items),
        ],
        child: MaterialApp(
          theme: theme,
          home: Scaffold(body: page),
        ),
      );

  testWidgets('liabilities semantic rows · dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 700));
    await tester.pumpWidget(
      liabHost(buildDarkTheme(), const LiabilitiesPage(), [
        liab('cc_owing', '招行信用卡', '-2000.00'),
        liab('cc_paid', '交行信用卡', '0.00'),
        liab('cc_over', '广发信用卡', '500.00'),
        liab('loan_psbc', '邮储助学贷款', '-9620.00'),
      ]),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(LiabilitiesPage),
      matchesGoldenFile('goldens/liabilities_semantic_dark.png'),
    );
  });

  testWidgets('liabilities empty · dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 700));
    await tester.pumpWidget(
      liabHost(buildDarkTheme(), const LiabilitiesPage(), const []),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(LiabilitiesPage),
      matchesGoldenFile('goldens/liabilities_empty_dark.png'),
    );
  });

  testWidgets('account form credit-card · dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 900));
    await tester.pumpWidget(
      liabHost(
        buildDarkTheme(),
        const AccountFormPage(initialType: AccountType.creditCard),
        const [],
      ),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(AccountFormPage),
      matchesGoldenFile('goldens/account_form_credit_card_dark.png'),
    );
  });

  testWidgets('account type picker · dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(500, 760));
    await tester.pumpWidget(
      liabHost(
        buildDarkTheme(),
        const Center(
          child: AccountTypePickerDialog(selected: AccountType.creditCard),
        ),
        const [],
      ),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(AccountTypePickerDialog),
      matchesGoldenFile('goldens/account_type_picker_dark.png'),
    );
  });

  // —— DCA 真实成交记录表单（2026-07-16 批）——
  testWidgets('dca execution dialog · dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(460, 760));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: const Scaffold(
          body: Center(
            child: DcaExecutionDialog(
              reminder: DcaReminderVm(
                id: 'rem_preview',
                planId: 'plan_preview',
                displayName: '沪深300ETF',
                plannedAmount: Money(amount: '200.00', currency: 'CNY'),
                dueDate: '2026-07-16',
                status: DcaReminderStatus.due,
              ),
              holdingAccounts: [
                AccountVm(
                  id: 'a1',
                  displayName: '美股券商',
                  accountType: AccountType.brokerage,
                  isLiability: false,
                  balanceMode: 'holdings',
                  defaultCurrency: 'USD',
                ),
                AccountVm(
                  id: 'a2',
                  displayName: '混合老账户',
                  accountType: AccountType.brokerage,
                  isLiability: false,
                  balanceMode: 'mixed',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(DcaExecutionDialog),
      matchesGoldenFile('goldens/dca_execution_dialog_dark.png'),
    );
  });
  // —— 手动投资成交（2026-07-17 批）——
  const tradeCaps = LedgerCapabilitiesVm(
    dataSourceMode: 'local_server',
    canWriteConfirmedLedger: true,
    canCreateAccount: true,
    canRecordMovement: true,
    canConfirmProposal: true,
    canPersistPendingProposal: true,
    proposalPersistence: 'file',
  );
  const tradeAccounts = [
    AccountVm(
      id: 'a_cash',
      displayName: '招行储蓄卡',
      accountType: AccountType.bank,
      isLiability: false,
      balanceMode: 'cash_balance',
      defaultCurrency: 'CNY',
      supportedCurrencies: ['CNY'],
    ),
    AccountVm(
      id: 'a_hold',
      displayName: 'A股券商',
      accountType: AccountType.brokerage,
      isLiability: false,
      balanceMode: 'holdings',
      defaultCurrency: 'CNY',
      supportedCurrencies: ['CNY'],
    ),
  ];
  const tradeInstruments = [
    InstrumentVm(
      id: 'inst_300',
      type: InstrumentType.fund,
      symbol: '510300',
      displayName: '沪深300ETF',
      quoteCurrency: 'CNY',
    ),
    InstrumentVm(
      id: 'inst_500',
      type: InstrumentType.fund,
      symbol: '510500',
      displayName: '中证500ETF',
      quoteCurrency: 'CNY',
    ),
  ];

  Widget tradeHost(ThemeData theme) => ProviderScope(
    overrides: [
      capabilitiesProvider.overrideWith((ref) async => tradeCaps),
      accountsProvider.overrideWith((ref) async => tradeAccounts),
      instrumentsProvider.overrideWith((ref) async => tradeInstruments),
      portfolioRepositoryProvider.overrideWithValue(
        const _PreviewPortfolioRepo(),
      ),
    ],
    // _submit 依赖 GoRouter；预览用最小路由环境。
    child: MaterialApp.router(
      theme: theme,
      routerConfig: GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const InvestmentTradePage()),
        ],
      ),
    ),
  );

  Future<void> pickField(WidgetTester tester, Key key, String option) async {
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  Future<void> fillBuy(WidgetTester tester) async {
    await pickField(tester, kTradeCashAccountFieldKey, '招行储蓄卡');
    await pickField(tester, kTradeHoldingAccountFieldKey, 'A股券商');
    await pickField(tester, kTradeInstrumentFieldKey, '沪深300ETF · 510300');
    await tester.enterText(find.widgetWithText(TextField, '成交数量'), '10');
    await tester.enterText(find.widgetWithText(TextField, '成交价款'), '4128.00');
    // 等 label 浮动动画完成，避免文字与标签叠印。
    await tester.pumpAndSettle();
  }

  testWidgets('trade form buy - phone dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(360, 800));
    await tester.pumpWidget(tradeHost(buildDarkTheme()));
    await _settleEntrance(tester);
    await fillBuy(tester);
    await expectLater(
      find.byType(InvestmentTradePage),
      matchesGoldenFile('goldens/trade_form_buy_phone_dark.png'),
    );
  });

  testWidgets(
    'trade form sell over-quantity - phone dark',
    skip: !_previewEnabled,
    (tester) async {
      await sized(tester, const Size(360, 800));
      await tester.pumpWidget(tradeHost(buildDarkTheme()));
      await _settleEntrance(tester);
      await tester.tap(find.text('卖出'));
      await tester.pumpAndSettle();
      await pickField(tester, kTradeCashAccountFieldKey, '招行储蓄卡');
      await pickField(tester, kTradeHoldingAccountFieldKey, 'A股券商');
      await pickField(tester, kTradeInstrumentFieldKey, '沪深300ETF · 510300');
      await tester.enterText(find.widgetWithText(TextField, '成交数量'), '7');
      await tester.enterText(
        find.widgetWithText(TextField, '卖出毛回款'),
        '2900.00',
      );
      await tester.pump();
      // 滚到底部展示跨字段错误与禁用按钮。
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(InvestmentTradePage),
        matchesGoldenFile('goldens/trade_form_sell_error_phone_dark.png'),
      );
    },
  );

  testWidgets('trade form buy - desktop light', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(1200, 800));
    await tester.pumpWidget(tradeHost(buildLightTheme()));
    await _settleEntrance(tester);
    await fillBuy(tester);
    await expectLater(
      find.byType(InvestmentTradePage),
      matchesGoldenFile('goldens/trade_form_buy_desktop_light.png'),
    );
  });

  testWidgets('trade confirm buy - light', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(420, 800));
    await tester.pumpWidget(tradeHost(buildLightTheme()));
    await _settleEntrance(tester);
    await fillBuy(tester);
    await tester.enterText(find.widgetWithText(TextField, '手续费（可选）'), '2.00');
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认买入'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(kTradeConfirmDialogKey),
      matchesGoldenFile('goldens/trade_confirm_buy_light.png'),
    );
  });

  testWidgets('trade confirm sell - dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(420, 800));
    await tester.pumpWidget(tradeHost(buildDarkTheme()));
    await _settleEntrance(tester);
    await tester.tap(find.text('卖出'));
    await tester.pumpAndSettle();
    await pickField(tester, kTradeCashAccountFieldKey, '招行储蓄卡');
    await pickField(tester, kTradeHoldingAccountFieldKey, 'A股券商');
    await pickField(tester, kTradeInstrumentFieldKey, '沪深300ETF · 510300');
    await tester.enterText(find.widgetWithText(TextField, '成交数量'), '4');
    await tester.enterText(find.widgetWithText(TextField, '卖出毛回款'), '1660.00');
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, '手续费（可选）'), '1.00');
    await tester.enterText(find.widgetWithText(TextField, '税费（可选）'), '1.66');
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认卖出'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(kTradeConfirmDialogKey),
      matchesGoldenFile('goldens/trade_confirm_sell_dark.png'),
    );
  });

  // —— 成交详情：同币种盈利 / 跨币种亏损 + 换算依据 ——
  Widget detailHost(ThemeData theme, MovementVm movement) => ProviderScope(
    overrides: [
      capabilitiesProvider.overrideWith((ref) async => tradeCaps),
      accountsProvider.overrideWith((ref) async => tradeAccounts),
      movementRepositoryProvider.overrideWithValue(
        _PreviewMovementRepo(movement),
      ),
    ],
    child: MaterialApp(
      theme: theme,
      home: const MovementDetailPage(movementId: 'mov_preview'),
    ),
  );

  final profitSale = parseMovementData({
    'id': 'mov_preview',
    'atomicGroupId': 'ag_preview',
    'type': 'sell',
    'status': 'confirmed',
    'title': '卖出 沪深300ETF',
    'occurredAt': '2026-07-16T10:30:00Z',
    'entries': [
      {
        'accountId': 'a_hold',
        'instrumentId': 'inst_300',
        'amount': '4',
        'currency': 'CNY',
        'direction': 'out',
        'role': 'source',
      },
      {
        'accountId': 'a_cash',
        'amount': '1660.00',
        'currency': 'CNY',
        'direction': 'in',
        'role': 'destination',
      },
    ],
    'saleResult': {
      'costBasisMethod': 'average_cost',
      'grossProceeds': {'amount': '1660.00', 'currency': 'CNY'},
      'feeAndTaxTotal': {'amount': '2.66', 'currency': 'CNY'},
      'netProceeds': {'amount': '1657.34', 'currency': 'CNY'},
      'costBasisReleased': {'amount': '1651.20', 'currency': 'CNY'},
      'realizedPnl': {'amount': '6.14', 'currency': 'CNY'},
      'realizedPnlStatus': 'calculated',
    },
  });

  final fxLossSale = parseMovementData({
    'id': 'mov_preview',
    'atomicGroupId': 'ag_preview',
    'type': 'sell',
    'status': 'confirmed',
    'title': '卖出 纳指ETF',
    'occurredAt': '2026-07-16T00:00:00Z',
    'entries': [
      {
        'accountId': 'a_hold',
        'instrumentId': 'inst_ndx',
        'amount': '2',
        'currency': 'USD',
        'direction': 'out',
        'role': 'source',
      },
      {
        'accountId': 'a_cash',
        'amount': '20.00',
        'currency': 'CNY',
        'direction': 'in',
        'role': 'destination',
      },
    ],
    'saleResult': {
      'costBasisMethod': 'average_cost',
      'grossProceeds': {'amount': '20.00', 'currency': 'CNY'},
      'feeAndTaxTotal': {'amount': '0', 'currency': 'CNY'},
      'netProceeds': {'amount': '20.00', 'currency': 'CNY'},
      'costBasisReleased': {'amount': '20.00', 'currency': 'USD'},
      'realizedPnl': {'amount': '-17.20', 'currency': 'USD'},
      'netProceedsInCostBasisCurrency': {'amount': '2.80', 'currency': 'USD'},
      'fxBasis': {
        'baseCurrency': 'CNY',
        'quoteCurrency': 'USD',
        'rate': '0.14',
        'asOf': '2026-07-15T00:00:00Z',
        'sourceRateId': 'fx_internal_preview',
        'source': 'manual',
        'inverted': false,
      },
      'realizedPnlStatus': 'calculated_with_fx',
    },
  });

  testWidgets('trade detail profit - dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 800));
    await tester.pumpWidget(detailHost(buildDarkTheme(), profitSale));
    await _settleEntrance(tester);
    await expectLater(
      find.byType(MovementDetailPage),
      matchesGoldenFile('goldens/trade_detail_profit_dark.png'),
    );
  });

  testWidgets('trade detail fx loss - dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 860));
    await tester.pumpWidget(detailHost(buildDarkTheme(), fxLossSale));
    await _settleEntrance(tester);
    // 展开换算依据（默认折叠）。
    await tester.tap(find.text('换算依据'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MovementDetailPage),
      matchesGoldenFile('goldens/trade_detail_fx_loss_dark.png'),
    );
  });

  testWidgets('trade detail fx loss - desktop light', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(1440, 900));
    await tester.pumpWidget(detailHost(buildLightTheme(), fxLossSale));
    await _settleEntrance(tester);
    await tester.tap(find.text('换算依据'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MovementDetailPage),
      matchesGoldenFile('goldens/trade_detail_fx_loss_desktop_light.png'),
    );
  });
  // —— 2026-07-18 批：订阅双日期表单 / 估值状态面板 / 多资产账户详情 ——
  const okxAccount = AccountVm(
    id: 'a_okx',
    displayName: 'OKX',
    accountType: AccountType.exchange,
    isLiability: false,
    balanceMode: 'mixed',
    defaultCurrency: 'USDT',
    supportedCurrencies: ['USDT', 'BTC', 'ETH'],
    cashBalances: {'USDT': '123.45'},
    value: ValuedMoney(
      amount: '890.00',
      currency: 'CNY',
      asOf: '2026-07-18T09:00:00+08:00',
      quality: ValueQuality.incomplete,
    ),
  );
  const okxHoldings = [
    HoldingVm(
      id: 'h_btc',
      accountId: 'a_okx',
      instrumentId: 'inst_btc',
      symbol: 'BTC',
      displayName: 'Bitcoin',
      quantity: '0.00076078',
      quoteStatus: QuoteStatus.fresh,
      marketValue: ValuedMoney(
        amount: '380.00',
        currency: 'CNY',
        asOf: '2026-07-18T09:00:00+08:00',
        quality: ValueQuality.estimated,
      ),
    ),
    HoldingVm(
      id: 'h_eth',
      accountId: 'a_okx',
      instrumentId: 'inst_eth',
      symbol: 'ETH',
      displayName: 'Ethereum',
      quantity: '0.25',
      quoteStatus: QuoteStatus.unpriceable,
    ),
  ];

  Widget accountDetailHost(ThemeData theme) => ProviderScope(
    overrides: [
      capabilitiesProvider.overrideWith((ref) async => tradeCaps),
      accountRepositoryProvider.overrideWithValue(
        const _PreviewAccountRepo(okxAccount),
      ),
      portfolioRepositoryProvider.overrideWithValue(
        const _PreviewCryptoPortfolioRepo(okxHoldings),
      ),
      instrumentsProvider.overrideWith((ref) async => const <InstrumentVm>[]),
    ],
    child: MaterialApp.router(
      theme: theme,
      routerConfig: GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const AccountDetailPage(accountId: 'a_okx'),
          ),
        ],
      ),
    ),
  );

  testWidgets('multi-asset account detail - dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 820));
    await tester.pumpWidget(accountDetailHost(buildDarkTheme()));
    await _settleEntrance(tester);
    await expectLater(
      find.byType(AccountDetailPage),
      matchesGoldenFile('goldens/account_multi_asset_dark.png'),
    );
  });

  testWidgets('multi-asset account detail - light', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 820));
    await tester.pumpWidget(accountDetailHost(buildLightTheme()));
    await _settleEntrance(tester);
    await expectLater(
      find.byType(AccountDetailPage),
      matchesGoldenFile('goldens/account_multi_asset_light.png'),
    );
  });

  Widget valuationHost(ThemeData theme) => ProviderScope(
    overrides: [
      accountsProvider.overrideWith((ref) async => const [okxAccount]),
      holdingsProvider.overrideWith((ref) async => okxHoldings),
      fxRatesProvider.overrideWith((ref) async => const <FxRateVm>[]),
    ],
    child: MaterialApp(
      theme: theme,
      home: const Scaffold(body: Center(child: ValuationStatusDialog())),
    ),
  );

  testWidgets('valuation status dialog - dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(460, 700));
    await tester.pumpWidget(valuationHost(buildDarkTheme()));
    await _settleEntrance(tester);
    await expectLater(
      find.byType(ValuationStatusDialog),
      matchesGoldenFile('goldens/valuation_status_dialog_dark.png'),
    );
  });

  Widget subFormHost(ThemeData theme) => ProviderScope(
    overrides: [
      capabilitiesProvider.overrideWith((ref) async => tradeCaps),
      accountsProvider.overrideWith((ref) async => tradeAccounts),
    ],
    child: MaterialApp.router(
      theme: theme,
      routerConfig: GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const SubscriptionFormPage()),
        ],
      ),
    ),
  );

  testWidgets('subscription form dual dates - dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 1120));
    await tester.pumpWidget(subFormHost(buildDarkTheme()));
    await _settleEntrance(tester);
    await expectLater(
      find.byType(SubscriptionFormPage),
      matchesGoldenFile('goldens/subscription_form_dual_dates_dark.png'),
    );
  });
  // —— 2026-07-18 批 2：贷款条款 / 贷款区 ——
  const loanPreviewAccount = AccountVm(
    id: 'a_loan',
    displayName: '邮储助学贷款',
    accountType: AccountType.loan,
    isLiability: true,
    balanceMode: 'liability',
    defaultCurrency: 'CNY',
    cashBalances: {'CNY': '-400.00'},
  );

  final loanPosition = parseLiabilityPositionData({
    'accountId': 'a_loan',
    'accountName': '邮储助学贷款',
    'currency': 'CNY',
    'terms': {
      'liabilityType': 'student_loan',
      'annualRate': '0.365',
      'rateType': 'fixed',
      'dayCountBasis': 365,
      'interestStartDate': '2026-01-01',
      'maturityDate': '2026-12-01',
      'repaymentStartDate': '2026-02-01',
      'nextDueDate': '2026-02-01',
      'repaymentFrequency': 'monthly',
      'scheduledPayment': {'amount': '100.00', 'currency': 'CNY'},
      'paymentAccountId': 'a_cash',
      'lastInterestAccruedThrough': '2026-01-01',
      'updatedAt': '2026-07-18T00:00:00Z',
    },
    'outstandingPrincipal': {'amount': '400.00', 'currency': 'CNY'},
    'accruedThrough': '2026-01-31',
    'accrualDays': 30,
    'accruedInterest': {'amount': '12.00', 'currency': 'CNY'},
    'nextPayment': {
      'dueDate': '2026-02-01',
      'scheduledAmount': {'amount': '100.00', 'currency': 'CNY'},
      'projectedInterest': {'amount': '12.40', 'currency': 'CNY'},
      'projectedPrincipal': {'amount': '87.60', 'currency': 'CNY'},
    },
    'status': 'active',
  });

  Widget loanHost(ThemeData theme, Widget page) => ProviderScope(
    overrides: [
      capabilitiesProvider.overrideWith((ref) async => tradeCaps),
      accountsProvider.overrideWith((ref) async => tradeAccounts),
      accountRepositoryProvider.overrideWithValue(
        const _PreviewAccountRepo(loanPreviewAccount),
      ),
      loanRepositoryProvider.overrideWithValue(
        _PreviewLoanRepo([loanPosition]),
      ),
    ],
    child: MaterialApp.router(
      theme: theme,
      routerConfig: GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => page)],
      ),
    ),
  );

  testWidgets('loan section - dark', skip: !_previewEnabled, (tester) async {
    await sized(tester, const Size(400, 760));
    await tester.pumpWidget(
      loanHost(
        buildDarkTheme(),
        const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: LoanSection(account: loanPreviewAccount),
            ),
          ),
        ),
      ),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/loan_section_dark.png'),
    );
  });

  testWidgets('loan section - light', skip: !_previewEnabled, (tester) async {
    await sized(tester, const Size(400, 760));
    await tester.pumpWidget(
      loanHost(
        buildLightTheme(),
        const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: LoanSection(account: loanPreviewAccount),
            ),
          ),
        ),
      ),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/loan_section_light.png'),
    );
  });

  testWidgets('liability terms form - dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 1240));
    await tester.pumpWidget(
      loanHost(buildDarkTheme(), const LiabilityTermsPage(accountId: 'a_loan')),
    );
    await _settleEntrance(tester);
    await expectLater(
      find.byType(LiabilityTermsPage),
      matchesGoldenFile('goldens/liability_terms_form_dark.png'),
    );
  });
  // —— 2026-07-19 批：AI 文本整理复核卡（结构化 + 待补全）——
  final aiTextProposals = [
    parseAiProposalData({
      'id': 'prop_text_1',
      'status': 'pending',
      'source': {
        'kind': 'user_text',
        'modelName': 'gpt-x-preview',
        'evidenceRefs': [
          {'label': '午餐 18 元'},
        ],
      },
      'atomicGroups': [
        {
          'id': 'ag_text_1',
          'title': '新增：午餐',
          'operation': 'create',
          'status': 'pending',
          'proposedMovements': [
            {
              'id': 'mov_text_1',
              'atomicGroupId': 'ag_text_1',
              'type': 'expense',
              'status': 'pending_review',
              'title': '午餐',
              'occurredAt': '2026-07-19T12:30:00+08:00',
              'entries': [
                {
                  'accountId': 'a_cash',
                  'amount': '18',
                  'currency': 'CNY',
                  'direction': 'out',
                  'role': 'source',
                },
              ],
            },
          ],
          'diffs': <Object>[],
          'warnings': <Object>[],
          'validation': {'isValid': true, 'errors': <Object>[]},
        },
      ],
    }),
    parseAiProposalData({
      'id': 'prop_text_2',
      'status': 'pending',
      'source': {
        'kind': 'user_text',
        'evidenceRefs': [
          {'label': '上个月好像还有笔水电费'},
        ],
      },
      'atomicGroups': [
        {
          'id': 'ag_text_2',
          'title': '文本：待补全',
          'operation': 'create',
          'status': 'pending',
          'proposedMovements': <Object>[],
          'diffs': <Object>[],
          'warnings': <Object>[],
          'validation': {'isValid': false, 'errors': <Object>[]},
        },
      ],
    }),
  ];

  Widget aiTextReviewHost(ThemeData theme) => ProviderScope(
    overrides: [
      capabilitiesProvider.overrideWith((ref) async => tradeCaps),
      accountsProvider.overrideWith(
        (ref) async => const [
          AccountVm(
            id: 'a_cash',
            displayName: '现金钱包',
            accountType: AccountType.cash,
            isLiability: false,
            defaultCurrency: 'CNY',
          ),
        ],
      ),
      aiProposalRepositoryProvider.overrideWithValue(
        _PreviewAiRepo(aiTextProposals),
      ),
    ],
    child: MaterialApp.router(
      theme: theme,
      routerConfig: GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const AiReviewPage()),
          GoRoute(path: '/ai-edit/:id', builder: (_, _) => const Placeholder()),
        ],
      ),
    ),
  );

  testWidgets('ai text review cards - dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 860));
    await tester.pumpWidget(aiTextReviewHost(buildDarkTheme()));
    await _settleEntrance(tester);
    await expectLater(
      find.byType(AiReviewPage),
      matchesGoldenFile('goldens/ai_text_review_dark.png'),
    );
  });

  testWidgets('ai text import unavailable - dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 700));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          capabilitiesProvider.overrideWith((ref) async => tradeCaps),
          aiProposalRepositoryProvider.overrideWithValue(
            _PreviewAiRepo(const [], failCreate: true),
          ),
        ],
        child: MaterialApp.router(
          theme: buildDarkTheme(),
          routerConfig: GoRouter(
            routes: [
              GoRoute(path: '/', builder: (_, _) => const AiImportTextPage()),
            ],
          ),
        ),
      ),
    );
    await _settleEntrance(tester);
    await tester.enterText(find.byType(TextField), '午餐 18 元');
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(AiImportTextPage),
      matchesGoldenFile('goldens/ai_text_import_unavailable_dark.png'),
    );
  });

  // —— 2026-07-28 批：Agent 控制中枢 ——
  const agentConversation = AgentConversationVm(
    id: 'conv_1',
    title: '主会话',
    isPrimary: true,
    status: AgentConversationStatus.active,
    createdAt: '2026-07-28T00:00:00Z',
    updatedAt: '2026-07-28T00:00:00Z',
  );

  AgentMessageVm agentMessage(
    String id,
    AgentMessageRole role,
    String text, {
    List<String> attachmentIds = const [],
    AgentMessageStatus status = AgentMessageStatus.completed,
  }) => AgentMessageVm(
    id: id,
    conversationId: 'conv_1',
    role: role,
    text: text,
    status: status,
    createdAt: '2026-07-28T00:00:00Z',
    attachmentIds: attachmentIds,
  );

  // Image.memory 的解码是异步的：golden 里必须先 precache 再 pump，否则只画出空位。
  Future<void> decodeImages(WidgetTester tester) async {
    final context = tester.element(find.byType(AgentPanel));
    for (var round = 0; round < 3; round += 1) {
      await tester.runAsync(() async {
        for (final image in tester.widgetList<Image>(find.byType(Image))) {
          await precacheImage(image.image, context);
        }
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Widget agentHost(
    ThemeData theme, {
    bool configured = true,
    List<AgentMessageVm> messages = const [],
    List<AgentMemoryVm> memories = const [],
    List<AgentEventVm> events = const [],
    AgentFilePicker? picker,
    List<AgentQuoteCandidateVm> candidates = const [],
    AgentAttachmentVm? attachmentMeta,
    List<AgentNotificationVm> notifications = const [],
    Object? statusFailure,
    double? railWidth,
  }) => ProviderScope(
    overrides: [
      if (picker != null)
        agentAttachmentPickerProvider.overrideWithValue(picker),
      capabilitiesProvider.overrideWith((ref) async => tradeCaps),
      accountsProvider.overrideWith((ref) async => const <AccountVm>[]),
      aiPendingProvider.overrideWith((ref) async => const <AiProposalVm>[]),
      instrumentsProvider.overrideWith(
        (ref) async => const [
          InstrumentVm(
            id: 'inst_btc',
            type: InstrumentType.crypto,
            displayName: 'Bitcoin',
            symbol: 'BTC',
            quoteCurrency: 'USDT',
          ),
        ],
      ),
      agentRepositoryProvider.overrideWithValue(
        _PreviewAgentRepo(
          configured: configured,
          messages: messages,
          memories: memories,
          frames: events,
          conversations: const [agentConversation],
          candidates: candidates,
          attachmentMeta: attachmentMeta,
          notifications: notifications,
          statusFailure: statusFailure,
        ),
      ),
    ],
    child: MaterialApp(
      theme: theme,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: railWidth == null
            ? const AgentPanel()
            // Windows 右栏：面板固定宽度，左边留主内容区。
            : Row(
                children: [
                  const Expanded(child: SizedBox.expand()),
                  const VerticalDivider(width: 1),
                  SizedBox(width: railWidth, child: const AgentPanel()),
                ],
              ),
      ),
    ),
  );

  for (final (name, theme) in [
    ('dark', buildDarkTheme()),
    ('light', buildLightTheme()),
  ]) {
    testWidgets('agent panel empty - $name', skip: !_previewEnabled, (
      tester,
    ) async {
      await sized(tester, const Size(400, 640));
      await tester.pumpWidget(agentHost(theme));
      await _settleEntrance(tester);
      await expectLater(
        find.byType(AgentPanel),
        matchesGoldenFile('goldens/agent_panel_empty_$name.png'),
      );
    });

    testWidgets('agent panel streaming - $name', skip: !_previewEnabled, (
      tester,
    ) async {
      await sized(tester, const Size(400, 640));
      await tester.pumpWidget(
        agentHost(
          theme,
          messages: [agentMessage('m1', AgentMessageRole.user, '帮我看看这张账单')],
          events: const [
            AgentEventVm(
              cursor: 1,
              type: AgentEventType.runQueued,
              runId: 'run_1',
              userMessageId: 'm1',
              assistantMessageId: 'm2',
            ),
            AgentEventVm(
              cursor: 2,
              type: AgentEventType.runStarted,
              runId: 'run_1',
              assistantMessageId: 'm2',
            ),
            AgentEventVm(
              cursor: 3,
              type: AgentEventType.messageDelta,
              assistantMessageId: 'm2',
              delta: '这张账单里有 3 笔支出，',
            ),
            AgentEventVm(
              cursor: 4,
              type: AgentEventType.messageDelta,
              assistantMessageId: 'm2',
              delta: '我按商户归了类。',
            ),
            AgentEventVm(
              cursor: 5,
              type: AgentEventType.toolStarted,
              runId: 'run_1',
              toolName: 'finwealth_query',
            ),
          ],
        ),
      );
      await _settleEntrance(tester);
      await expectLater(
        find.byType(AgentPanel),
        matchesGoldenFile('goldens/agent_panel_streaming_$name.png'),
      );
    });
  }

  // —— 2026-07-29 批：对话渲染改造 ——
  const markdownAnswer =
      '这个月的现金流我按三块看：\n\n'
      '- 固定支出仍是房贷与订阅，占比最大\n'
      '- 浮动支出集中在餐饮\n'
      '- 结余已经转入货币基金\n\n'
      '需要我把 `餐饮` 这一类单独拉出来吗？\n\n'
      '```text\n固定 12,400\n浮动  3,180\n结余  4,220\n```';

  for (final (name, theme) in [
    ('dark', buildDarkTheme()),
    ('light', buildLightTheme()),
  ]) {
    testWidgets('agent chat markdown - $name', skip: !_previewEnabled, (
      tester,
    ) async {
      await sized(tester, const Size(360, 720));
      await tester.pumpWidget(
        agentHost(
          theme,
          messages: [
            agentMessage('m1', AgentMessageRole.user, '这个月的钱都花哪了'),
            agentMessage('m2', AgentMessageRole.assistant, markdownAnswer),
          ],
        ),
      );
      await _settleEntrance(tester);
      await expectLater(
        find.byType(AgentPanel),
        matchesGoldenFile('goldens/agent_chat_markdown_$name.png'),
      );
    });

    testWidgets(
      'agent chat activity attachment - $name',
      skip: !_previewEnabled,
      (tester) async {
        await sized(tester, const Size(360, 720));
        await tester.pumpWidget(
          agentHost(
            theme,
            messages: [
              agentMessage(
                'm1',
                AgentMessageRole.user,
                '这份对账单帮我看下',
                attachmentIds: ['att_1'],
              ),
            ],
            attachmentMeta: const AgentAttachmentVm(
              id: 'att_1',
              fileName: '2026-06-statement.pdf',
              mimeType: 'application/pdf',
              sizeBytes: 184320,
              sha256: 'b',
              createdAt: '2026-07-29T00:00:00Z',
            ),
            events: const [
              AgentEventVm(
                cursor: 1,
                type: AgentEventType.toolStarted,
                runId: 'run_1',
                toolName: 'finwealth_lookup_fx_candidate',
              ),
            ],
          ),
        );
        await _settleEntrance(tester);
        await expectLater(
          find.byType(AgentPanel),
          matchesGoldenFile('goldens/agent_chat_activity_$name.png'),
        );
      },
    );

    testWidgets('agent chat wide panel - $name', skip: !_previewEnabled, (
      tester,
    ) async {
      await sized(tester, const Size(1280, 720));
      await tester.pumpWidget(
        agentHost(
          theme,
          railWidth: 360,
          messages: [
            agentMessage('m1', AgentMessageRole.user, '把上半年的结余讲清楚'),
            agentMessage(
              'm2',
              AgentMessageRole.assistant,
              '$markdownAnswer\n\n补充一句：上半年结余的节奏比去年稳，'
                  '主要是浮动支出没有再出现单月冲高，'
                  '所以即使收入没有变化，结余曲线也是逐月抬升的。',
            ),
          ],
        ),
      );
      await _settleEntrance(tester);
      await expectLater(
        find.byType(AgentPanel),
        matchesGoldenFile('goldens/agent_chat_wide_panel_$name.png'),
      );
    });
  }

  // 草稿区（待发送图片）：用注入的选图器，不驱动真实系统文件对话框。
  for (final (name, theme) in [
    ('dark', buildDarkTheme()),
    ('light', buildLightTheme()),
  ]) {
    testWidgets('agent panel draft image - $name', skip: !_previewEnabled, (
      tester,
    ) async {
      await sized(tester, const Size(400, 560));
      await tester.pumpWidget(
        agentHost(
          theme,
          picker: () async => (
            fileName: 'wechat-bill.png',
            bytes: base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAeklEQVR4'
              'nO3PUQkAIBTAwJfbJKYxmyH8OITBAtxm7fN1wwUNaEEDWtCAFjSgBQ1o'
              'QQNa0IAWNKAFDWhBA1rQgBY0oAUNaEEDWtCAFjSgBQ1oQQNa0IAWNKAF'
              'DWhBA1rQgBY0oAUNaEEDWtCAFjSgBQ1oQQNa0IAWPHYB8LwBtMtZwAUA'
              'AAAASUVORK5CYII=',
            ),
          ),
        ),
      );
      await _settleEntrance(tester);
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pumpAndSettle();
      await decodeImages(tester);
      await expectLater(
        find.byType(AgentPanel),
        matchesGoldenFile('goldens/agent_panel_draft_image_$name.png'),
      );
    });
  }

  for (final (name, theme) in [
    ('dark', buildDarkTheme()),
    ('light', buildLightTheme()),
  ]) {
    testWidgets('agent panel quote candidate - $name', skip: !_previewEnabled, (
      tester,
    ) async {
      await sized(tester, const Size(400, 560));
      await tester.pumpWidget(
        agentHost(
          theme,
          candidates: const [
            AgentQuoteCandidateVm(
              id: 'qc_1',
              kind: AgentQuoteCandidateKind.instrument,
              instrumentId: 'inst_btc',
              price: '61234.50',
              currency: 'USDT',
              asOf: '2026-07-28T09:30:00Z',
              source: 'CoinGecko',
              sourceUrl: 'https://www.coingecko.com/en/coins/bitcoin',
              status: AgentQuoteCandidateStatus.suggested,
              createdAt: '2026-07-28T09:31:00Z',
              updatedAt: '2026-07-28T09:31:00Z',
            ),
          ],
        ),
      );
      await _settleEntrance(tester);
      await tester.tap(find.textContaining('报价建议'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/agent_panel_quote_candidate_$name.png'),
      );
    });
  }

  for (final (name, theme) in [
    ('dark', buildDarkTheme()),
    ('light', buildLightTheme()),
  ]) {
    testWidgets('agent panel draft document - $name', skip: !_previewEnabled, (
      tester,
    ) async {
      await sized(tester, const Size(400, 560));
      await tester.pumpWidget(
        agentHost(
          theme,
          picker: () async => (
            fileName: 'wechat-2026-07.csv',
            bytes: Uint8List.fromList(
              utf8.encode('date,amount\n2026-07-28,18.00\n'),
            ),
          ),
        ),
      );
      await _settleEntrance(tester);
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(AgentPanel),
        matchesGoldenFile('goldens/agent_panel_draft_document_$name.png'),
      );
    });

    testWidgets(
      'agent panel history document - $name',
      skip: !_previewEnabled,
      (tester) async {
        await sized(tester, const Size(400, 560));
        await tester.pumpWidget(
          agentHost(
            theme,
            messages: [
              agentMessage(
                'm1',
                AgentMessageRole.user,
                '这份对账单帮我看看',
                attachmentIds: const ['att_pdf'],
              ),
              agentMessage('m2', AgentMessageRole.assistant, '我已经拿到这份文件了。'),
            ],
            attachmentMeta: const AgentAttachmentVm(
              id: 'att_pdf',
              fileName: 'statement-2026-07.pdf',
              mimeType: 'application/pdf',
              sizeBytes: 243712,
              sha256: 'e',
              createdAt: '2026-07-28T00:00:00Z',
            ),
          ),
        );
        await _settleEntrance(tester);
        await expectLater(
          find.byType(AgentPanel),
          matchesGoldenFile('goldens/agent_panel_history_document_$name.png'),
        );
      },
    );
  }

  // —— 2026-07-28 批：自动任务与通知 ——
  AgentAutomationVm previewAutomation(
    AgentAutomationKind kind, {
    required int intervalHours,
    bool enabled = true,
    String? lastRunAt,
    AgentAutomationRunStatus? lastStatus,
  }) => AgentAutomationVm(
    id: 'auto_${kind.name}',
    kind: kind,
    intervalHours: intervalHours,
    enabled: enabled,
    nextRunAt: '2026-07-29T02:00:00Z',
    createdAt: '2026-07-28T00:00:00Z',
    updatedAt: '2026-07-28T00:00:00Z',
    lastRunAt: lastRunAt,
    lastStatus: lastStatus,
  );

  Widget automationHost(
    ThemeData theme, {
    List<AgentAutomationVm> automations = const [],
  }) => ProviderScope(
    overrides: [
      agentRepositoryProvider.overrideWithValue(
        _PreviewAgentRepo(
          configured: true,
          messages: const [],
          memories: const [],
          frames: const [],
          conversations: const [],
          automations: automations,
        ),
      ),
    ],
    child: MaterialApp(
      theme: theme,
      debugShowCheckedModeBanner: false,
      home: const AgentAutomationsPage(),
    ),
  );

  for (final (name, theme) in [
    ('dark', buildDarkTheme()),
    ('light', buildLightTheme()),
  ]) {
    testWidgets('agent automations empty - $name', skip: !_previewEnabled, (
      tester,
    ) async {
      await sized(tester, const Size(420, 620));
      await tester.pumpWidget(automationHost(theme));
      await _settleEntrance(tester);
      await expectLater(
        find.byType(AgentAutomationsPage),
        matchesGoldenFile('goldens/agent_automations_empty_$name.png'),
      );
    });

    testWidgets(
      'agent automations configured - $name',
      skip: !_previewEnabled,
      (tester) async {
        await sized(tester, const Size(420, 900));
        await tester.pumpWidget(
          automationHost(
            theme,
            automations: [
              previewAutomation(
                AgentAutomationKind.quoteRefresh,
                intervalHours: 6,
                lastRunAt: '2026-07-28T02:00:00Z',
                lastStatus: AgentAutomationRunStatus.success,
              ),
              previewAutomation(
                AgentAutomationKind.subscriptionDueScan,
                intervalHours: 24,
                lastRunAt: '2026-07-28T01:00:00Z',
                lastStatus: AgentAutomationRunStatus.failed,
              ),
              previewAutomation(
                AgentAutomationKind.dcaDueCheck,
                intervalHours: 24,
                enabled: false,
              ),
              previewAutomation(
                AgentAutomationKind.financialSummary,
                intervalHours: 168,
                lastRunAt: '2026-07-27T02:00:00Z',
                lastStatus: AgentAutomationRunStatus.success,
              ),
            ],
          ),
        );
        await _settleEntrance(tester);
        await expectLater(
          find.byType(AgentAutomationsPage),
          matchesGoldenFile('goldens/agent_automations_configured_$name.png'),
        );
      },
    );

    testWidgets('agent notifications - $name', skip: !_previewEnabled, (
      tester,
    ) async {
      await sized(tester, const Size(400, 620));
      await tester.pumpWidget(
        agentHost(
          theme,
          notifications: [
            const AgentNotificationVm(
              id: 'note_1',
              kind: AgentAutomationKind.subscriptionDueScan,
              title: '订阅到期扫描完成',
              body: '生成了 2 条待确认扣费',
              action: AgentNotificationAction.review,
              createdAt: '2026-07-28T09:30:00Z',
            ),
            const AgentNotificationVm(
              id: 'note_2',
              kind: AgentAutomationKind.financialSummary,
              title: '本周财务总结',
              body: '净资产较上周 +1.2%',
              action: AgentNotificationAction.agent,
              createdAt: '2026-07-27T09:30:00Z',
              readAt: '2026-07-27T10:00:00Z',
            ),
          ],
        ),
      );
      await _settleEntrance(tester);
      await tester.tap(find.textContaining('通知'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/agent_notifications_$name.png'),
      );
    });
  }

  for (final (name, theme) in [
    ('dark', buildDarkTheme()),
    ('light', buildLightTheme()),
  ]) {
    testWidgets('agent panel needs login - $name', skip: !_previewEnabled, (
      tester,
    ) async {
      await sized(tester, const Size(360, 640));
      await tester.pumpWidget(
        agentHost(
          theme,
          statusFailure: ApiUnauthorizedException('/v1/agent/status'),
        ),
      );
      await _settleEntrance(tester);
      await expectLater(
        find.byType(AgentPanel),
        matchesGoldenFile('goldens/agent_panel_needs_login_$name.png'),
      );
    });
  }

  testWidgets('agent panel unconfigured - dark', skip: !_previewEnabled, (
    tester,
  ) async {
    await sized(tester, const Size(400, 640));
    await tester.pumpWidget(agentHost(buildDarkTheme(), configured: false));
    await _settleEntrance(tester);
    await expectLater(
      find.byType(AgentPanel),
      matchesGoldenFile('goldens/agent_panel_unconfigured_dark.png'),
    );
  });

  for (final (name, theme) in [
    ('dark', buildDarkTheme()),
    ('light', buildLightTheme()),
  ]) {
    testWidgets(
      'agent panel memory and image - $name',
      skip: !_previewEnabled,
      (tester) async {
        await sized(tester, const Size(400, 720));
        await tester.pumpWidget(
          agentHost(
            theme,
            messages: [
              agentMessage('m1', AgentMessageRole.user, '这张微信账单帮我整理一下'),
              agentMessage(
                'm2',
                AgentMessageRole.assistant,
                '已经整理好 3 笔支出，去审核里确认就会入账。',
              ),
            ],
            memories: const [
              AgentMemoryVm(
                id: 'mem_1',
                content: '同一天的多笔支出分开记，不要合并',
                reason: '你已经纠正过两次',
                status: AgentMemoryStatus.suggested,
                createdAt: '2026-07-28T00:00:00Z',
                updatedAt: '2026-07-28T00:00:00Z',
              ),
            ],
          ),
        );
        await _settleEntrance(tester);
        await expectLater(
          find.byType(AgentPanel),
          matchesGoldenFile('goldens/agent_panel_memory_$name.png'),
        );
      },
    );
  }
}

/// 预览用 Agent 仓库：事件流一次性回放，用于渲染流式与工具活动的静态形态。
class _PreviewAgentRepo implements AgentRepository {
  const _PreviewAgentRepo({
    required this.configured,
    required this.messages,
    required this.memories,
    required this.frames,
    required this.conversations,
    this.candidates = const [],
    this.attachmentMeta,
    this.automations = const [],
    this.notifications = const [],
    this.statusFailure,
  });

  final bool configured;
  final List<AgentMessageVm> messages;
  final List<AgentMemoryVm> memories;
  final List<AgentEventVm> frames;
  final List<AgentConversationVm> conversations;
  final List<AgentQuoteCandidateVm> candidates;
  final AgentAttachmentVm? attachmentMeta;
  final List<AgentAutomationVm> automations;
  final List<AgentNotificationVm> notifications;
  final Object? statusFailure;

  @override
  Future<AgentStatusVm> getStatus() async {
    if (statusFailure != null) throw statusFailure!;
    return AgentStatusVm(
      configured: configured,
      modelCount: configured ? 1 : 0,
    );
  }

  @override
  Future<List<AgentModelVm>> listModels() async => configured
      ? const [
          AgentModelVm(
            id: 'preview/model',
            provider: 'preview',
            displayName: '预览模型',
            supportsImages: true,
          ),
        ]
      : const [];
  @override
  Future<List<AgentConversationVm>> listConversations() async => conversations;
  @override
  Future<List<AgentMessageVm>> listMessages(Id conversationId) async =>
      messages;
  // 预览里连接保持打开，静态形态才是流式态而不是断线态。
  @override
  Stream<AgentEventVm> events(Id conversationId, {int? after}) async* {
    yield* Stream.fromIterable(frames);
    await Completer<void>().future;
  }

  @override
  Future<List<AgentMemoryVm>> listMemories() async => memories;
  @override
  Future<Uint8List> getAttachmentContent(Id attachmentId) async => base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAIAAADYYG7QAAAAQklEQVR4'
    'nO3OQQ0AIAwAselGCWrQhguOR5MK6Kx9vjL5QEhISKgeCAkJCdUDISEh'
    'oXogJCQkVA+EhISE6oGQkNBjFzYGUPE+ORsjAAAAAElFTkSuQmCC',
  );
  @override
  Future<AgentAttachmentVm> getAttachment(Id attachmentId) async =>
      attachmentMeta ??
      AgentAttachmentVm(
        id: attachmentId,
        fileName: 'bill.png',
        mimeType: 'image/png',
        sizeBytes: 4096,
        sha256: 'd' * 64,
        createdAt: '2026-07-28T00:00:00Z',
      );
  @override
  Future<AgentAttachmentVm> uploadAttachment({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) async => AgentAttachmentVm(
    id: 'att_preview',
    fileName: fileName,
    mimeType: mimeType,
    sizeBytes: bytes.length,
    sha256: 'c' * 64,
    createdAt: '2026-07-28T00:00:00Z',
  );
  @override
  Future<AgentMemoryVm> reviewMemory(
    Id memoryId, {
    required AgentMemoryStatus decision,
  }) => throw UnsupportedError('preview');
  @override
  Future<AgentConversationVm> createConversation({String? title}) =>
      throw UnsupportedError('preview');
  @override
  Future<AgentConversationVm> updateConversation(
    Id conversationId, {
    String? title,
    AgentConversationStatus? status,
    String? modelId,
  }) => throw UnsupportedError('preview');
  @override
  Future<AgentRunAcceptedVm> sendMessage(
    Id conversationId, {
    required String text,
    List<Id> attachmentIds = const [],
  }) => throw UnsupportedError('preview');
  @override
  Future<List<AgentQuoteCandidateVm>> listQuoteCandidates() async => candidates;
  @override
  Future<AgentQuoteCandidateVm> reviewQuoteCandidate(
    Id candidateId, {
    required AgentQuoteCandidateStatus decision,
  }) => throw UnsupportedError('preview');
  @override
  Future<List<AgentAutomationVm>> listAutomations() async => automations;
  @override
  Future<List<AgentNotificationVm>> listNotifications() async => notifications;
  @override
  Future<AgentAutomationVm> createAutomation({
    required AgentAutomationKind kind,
    required int intervalHours,
    bool enabled = true,
    IsoDateTime? startAt,
  }) => throw UnsupportedError('preview');
  @override
  Future<AgentAutomationVm> updateAutomation(
    Id automationId, {
    int? intervalHours,
    bool? enabled,
    IsoDateTime? nextRunAt,
  }) => throw UnsupportedError('preview');
  @override
  Future<AgentAutomationVm> runAutomation(Id automationId) =>
      throw UnsupportedError('preview');
  @override
  Future<AgentNotificationVm> markNotificationRead(Id notificationId) =>
      throw UnsupportedError('preview');
  @override
  Future<void> cancelRun(Id runId) => throw UnsupportedError('preview');
}

/// 预览用 AI 提案仓库。
class _PreviewAiRepo implements AiProposalRepository {
  const _PreviewAiRepo(this.pending, {this.failCreate = false});
  final List<AiProposalVm> pending;
  final bool failCreate;

  @override
  Future<List<AiProposalVm>> listPending() async => pending;
  @override
  Future<AiProposalVm?> getProposal(Id id) async => null;
  @override
  Future<ConfirmResultVm> approveAtomicGroup(Id groupId) =>
      throw UnsupportedError('preview');
  @override
  Future<void> rejectAtomicGroup(Id groupId, {String? reason}) =>
      throw UnsupportedError('preview');
  @override
  Future<void> createFromText(String text) async {
    if (failCreate) {
      throw ApiServiceUnavailableException('/v1/ai/proposals/from-text');
    }
  }

  @override
  Future<void> createFromCsv(
    String csv, {
    Id? defaultAccountId,
    String? defaultCurrency,
  }) => throw UnsupportedError('preview');
  @override
  Future<void> createFromImage({
    required String fileName,
    required String imageBase64,
    String? mimeType,
  }) => throw UnsupportedError('preview');
  @override
  Future<void> editAtomicGroup(Id groupId, ManualRecordInput input) =>
      throw UnsupportedError('preview');
}

/// 预览用贷款仓库。
class _PreviewLoanRepo implements LoanRepository {
  const _PreviewLoanRepo(this.positions);
  final List<LiabilityPositionVm> positions;
  @override
  Future<List<LiabilityPositionVm>> listLiabilityPositions({
    IsoDate? throughDate,
  }) async => positions;
  @override
  Future<LoanRepaymentScheduleVm> getRepaymentSchedule(
    Id accountId, {
    int limit = 24,
  }) => throw UnsupportedError('preview');
  @override
  Future<AccountVm> updateLiabilityTerms(
    Id accountId,
    LiabilityTermsInput input,
  ) => throw UnsupportedError('preview');
  @override
  Future<AiAtomicGroupVm> proposeLoanInterest(
    Id accountId, {
    required IsoDate throughDate,
    String? note,
  }) => throw UnsupportedError('preview');
}

/// 预览用账户仓库（多资产账户详情）。
class _PreviewAccountRepo implements AccountRepository {
  const _PreviewAccountRepo(this.account);
  final AccountVm account;
  @override
  Future<AccountVm?> getAccount(Id id) async => account;
  @override
  Future<List<AccountVm>> listAccounts() async => [account];
  @override
  Future<List<AccountAnomalyVm>> listAnomalies() async => const [];
  @override
  Future<AccountVm> createAccount(CreateAccountInput input) =>
      throw UnsupportedError('preview');
  @override
  Future<AccountVm> updateAccount(Id id, CreateAccountInput input) =>
      throw UnsupportedError('preview');
  @override
  Future<void> archiveAccount(Id id) => throw UnsupportedError('preview');
}

/// 预览用持仓仓库（OKX 多资产）。
class _PreviewCryptoPortfolioRepo implements PortfolioRepository {
  const _PreviewCryptoPortfolioRepo(this.holdings);
  final List<HoldingVm> holdings;
  @override
  Future<List<HoldingVm>> listHoldingsByAccount(Id accountId) async => holdings;
  @override
  Future<List<HoldingVm>> listHoldings() async => holdings;
  @override
  Future<PortfolioOverviewVm> getOverview() async => const PortfolioOverviewVm(
    pendingSummary: PendingSummaryVm(),
    quoteStatusSummary: QuoteStatusSummaryVm(),
    primaryHoldings: [],
    recentMovements: [],
  );
  @override
  Future<AssetAllocationVm> getAssetAllocation() async =>
      const AssetAllocationVm(
        slices: [],
        totalAssets: Money(amount: '0', currency: 'CNY'),
        totalLiabilities: Money(amount: '0', currency: 'CNY'),
        netWorth: Money(amount: '0', currency: 'CNY'),
      );
  @override
  Future<AiAtomicGroupVm> proposeHoldingAdjustment(
    Id accountId,
    HoldingAdjustmentInput input,
  ) => throw UnsupportedError('preview');
}

/// 预览用只读 movement 仓库。
class _PreviewMovementRepo implements MovementRepository {
  const _PreviewMovementRepo(this.movement);
  final MovementVm movement;
  @override
  Future<MovementVm?> getMovement(Id id) async => movement;
  @override
  Future<List<MovementVm>> listRecentMovements({int limit = 20}) async =>
      const [];
  @override
  Future<ConfirmResultVm> createManualRecord(ManualRecordInput input) =>
      throw UnsupportedError('preview');
  @override
  Future<ConfirmResultVm> createTransfer(TransferInput input) =>
      throw UnsupportedError('preview');
  @override
  Future<ConfirmResultVm> reconcileBalance(ReconcileInput input) =>
      throw UnsupportedError('preview');
  @override
  Future<void> createCorrectionProposal(CreateCorrectionInput input) =>
      throw UnsupportedError('preview');
  @override
  Future<ConfirmResultVm> createInvestmentTrade(InvestmentTradeInput input) =>
      throw UnsupportedError('preview');
}

/// 预览用持仓仓库（卖出选择：沪深300ETF 持有 6）。
class _PreviewPortfolioRepo implements PortfolioRepository {
  const _PreviewPortfolioRepo();
  @override
  Future<PortfolioOverviewVm> getOverview() async => const PortfolioOverviewVm(
    pendingSummary: PendingSummaryVm(),
    quoteStatusSummary: QuoteStatusSummaryVm(),
    primaryHoldings: [],
    recentMovements: [],
  );
  @override
  Future<List<HoldingVm>> listHoldings() async => const [];
  @override
  Future<List<HoldingVm>> listHoldingsByAccount(Id accountId) async => const [
    HoldingVm(
      id: 'h_300',
      accountId: 'a_hold',
      instrumentId: 'inst_300',
      symbol: '510300',
      displayName: '沪深300ETF',
      quantity: '6',
      quoteStatus: QuoteStatus.fresh,
    ),
  ];
  @override
  Future<AssetAllocationVm> getAssetAllocation() async =>
      const AssetAllocationVm(
        slices: [],
        totalAssets: Money(amount: '0', currency: 'CNY'),
        totalLiabilities: Money(amount: '0', currency: 'CNY'),
        netWorth: Money(amount: '0', currency: 'CNY'),
      );
  @override
  Future<AiAtomicGroupVm> proposeHoldingAdjustment(
    Id accountId,
    HoldingAdjustmentInput input,
  ) => throw UnsupportedError('unused');
}
