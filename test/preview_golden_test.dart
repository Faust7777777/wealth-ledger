// 视觉预览（非回归断言）：用真实主题 + 真实 MiSans 字体把关键页渲成 PNG，
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
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/manual_record_page.dart';
import 'package:finwealth/features/overview_page.dart';
import 'package:finwealth/theme/app_theme.dart';

Future<void> _loadFonts() async {
  final bytes = File('assets/fonts/MiSans.ttf').readAsBytesSync();
  ByteData toData() => ByteData.view(Uint8List.fromList(bytes).buffer);
  // 应用 family 首选 Inter（未打包）→ 回退 MiSans；两个 family 都注册成 MiSans 字形，
  // 保证 golden 里所有文字都实打实渲染。
  for (final family in ['MiSans', 'Inter']) {
    final loader = FontLoader(family)..addFont(Future.value(toData()));
    await loader.load();
  }
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
}
