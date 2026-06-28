// Wealth Ledger — 应用根：MaterialApp.router + 深/浅主题 + DEMO 横幅。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/env.dart';
import '../data/providers.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'router.dart';

class WealthLedgerApp extends ConsumerStatefulWidget {
  const WealthLedgerApp({super.key});

  @override
  ConsumerState<WealthLedgerApp> createState() => _WealthLedgerAppState();
}

class _WealthLedgerAppState extends ConsumerState<WealthLedgerApp> {
  bool _startupRefreshScheduled = false;

  void _invalidateQuoteDerivedData() {
    ref.invalidate(overviewProvider);
    ref.invalidate(accountsProvider);
    ref.invalidate(holdingsProvider);
    ref.invalidate(allocationProvider);
    ref.invalidate(anomaliesProvider);
  }

  Future<void> _startupRefreshQuotes() async {
    try {
      await ref.read(quoteRepositoryProvider).refreshQuotes(mode: 'startup');
    } catch (_) {
      // 启动刷新失败不阻塞 App、不弹强干扰错误；待处理/报价状态由刷新后的读模型呈现。
    } finally {
      if (mounted) _invalidateQuoteDerivedData();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_startupRefreshScheduled) {
      _startupRefreshScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startupRefreshQuotes();
      });
    }

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
