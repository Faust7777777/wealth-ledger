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
    final banner = ref.watch(appEnvironmentProvider).devBannerLabel;

    return MaterialApp.router(
      title: 'Wealth Ledger',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: mode,
      routerConfig: appRouter,
      builder: (context, child) {
        final app = child ?? const SizedBox.shrink();
        // 非生产数据来源（DEMO/DEV）全局角标：不写入真实账本。
        if (banner == null) return app;
        return Banner(
          message: banner,
          location: BannerLocation.topEnd,
          color: AppColors.brand,
          child: app,
        );
      },
    );
  }
}
