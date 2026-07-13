// 视觉预览（非回归断言）：用真实主题 + 真实 Noto Sans/Serif SC 字体把关键页渲成 PNG，
// 供人肉眼/模型核验子主题、字体、间距、动效入场后的静态形态。
// 生成：PREVIEW_GOLDENS=1 flutter test --update-goldens test/preview_golden_test.dart
// 默认在普通 `flutter test` 中跳过（golden 依赖字体/Skia，跨机不稳，不做门禁）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finwealth/app/app.dart';
import 'package:finwealth/core/env.dart';
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/accounts_page.dart';
import 'package:finwealth/features/ai_review_page.dart';
import 'package:finwealth/features/investment_page.dart';
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
}
