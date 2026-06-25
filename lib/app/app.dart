// Wealth Ledger — 应用根：MaterialApp.router + 深/浅主题 + DEMO 横幅。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/env.dart';
import '../data/providers.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'router.dart';

class WealthLedgerApp extends ConsumerWidget {
  const WealthLedgerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final isDemo = ref.watch(appEnvironmentProvider).isDemo;

    return MaterialApp.router(
      title: 'Wealth Ledger',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: mode,
      routerConfig: appRouter,
      builder: (context, child) {
        final app = child ?? const SizedBox.shrink();
        // debug_fixture 模式全局 DEMO 角标：演示数据，不写入真实账本。
        if (!isDemo) return app;
        return Banner(
          message: 'DEMO',
          location: BannerLocation.topEnd,
          color: AppColors.brand,
          child: app,
        );
      },
    );
  }
}
