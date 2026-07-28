// Wealth Ledger — 应用根：MaterialApp.router + 深/浅主题 + DEMO 横幅。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/env.dart';
import '../data/providers.dart';
import '../features/app_update_controller.dart';
import '../features/remote_server_setup_page.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'router.dart';

class WealthLedgerApp extends ConsumerStatefulWidget {
  const WealthLedgerApp({super.key});

  @override
  ConsumerState<WealthLedgerApp> createState() => _WealthLedgerAppState();
}

class _WealthLedgerAppState extends ConsumerState<WealthLedgerApp> {
  static const Duration _scheduledQuoteRefreshInterval = Duration(minutes: 15);

  bool _startupRefreshScheduled = false;
  bool _startupUpdateCheckScheduled = false;
  bool _scheduledRefreshRunning = false;
  Timer? _scheduledQuoteRefreshTimer;

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

  Future<void> _scheduledRefreshQuotes() async {
    if (_scheduledRefreshRunning) return;
    _scheduledRefreshRunning = true;
    try {
      await ref.read(quoteRepositoryProvider).refreshQuotes(mode: 'scheduled');
    } catch (_) {
      // 定时刷新失败不弹强干扰错误；报价状态由状态区/待处理区表达。
    } finally {
      _scheduledRefreshRunning = false;
      if (mounted) _invalidateQuoteDerivedData();
    }
  }

  void _configureScheduledQuoteRefresh(AppEnvironment env) {
    final shouldRun = env.isApiBacked;
    if (!shouldRun) {
      _scheduledQuoteRefreshTimer?.cancel();
      _scheduledQuoteRefreshTimer = null;
      return;
    }
    if (_scheduledQuoteRefreshTimer != null) return;
    _scheduledQuoteRefreshTimer = Timer.periodic(
      _scheduledQuoteRefreshInterval,
      (_) => _scheduledRefreshQuotes(),
    );
  }

  @override
  void dispose() {
    _scheduledQuoteRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    final env = ref.watch(effectiveAppEnvironmentProvider);
    if (!env.hasConfiguredRemoteApi) {
      return MaterialApp(
        title: 'Wealth Ledger',
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: mode,
        home: const RemoteServerSetupPage(),
      );
    }
    if (!_startupRefreshScheduled) {
      _startupRefreshScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startupRefreshQuotes();
      });
    }
    // 应用内更新的静默检查：只在远端已配置且该平台/模式支持更新时触发一次。
    // 用 State 上的一次性闩锁，rebuild、切主题、切路由都不会再发第二个请求；
    // 未配置远端时上面已经提前 return，配置完成后这里才会第一次命中。
    if (!_startupUpdateCheckScheduled &&
        ref.read(clientUpdateServiceProvider) != null) {
      _startupUpdateCheckScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // 不阻塞首屏；失败不弹窗、不改登录态。
        unawaited(
          ref.read(appUpdateControllerProvider.notifier).checkSilently(),
        );
      });
    }

    _configureScheduledQuoteRefresh(env);
    final banner = env.devBannerLabel;

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
