// Wealth Ledger — go_router 配置：4 标签 shell + AI 复核 + dev token 预览。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/view_models.dart';
import '../dev/tokens_preview.dart';
import '../features/account_detail_page.dart';
import '../features/account_form_page.dart';
import '../features/accounts_page.dart';
import '../features/ai_import_text_page.dart';
import '../features/ai_review_page.dart';
import '../features/anomalies_page.dart';
import '../features/investment_page.dart';
import '../features/liabilities_page.dart';
import '../features/manual_record_page.dart';
import '../features/movement_detail_page.dart';
import '../features/overview_page.dart';
import '../features/settings_page.dart';
import '../features/snapshots_page.dart';
import 'home_shell.dart';

final appRouter = GoRouter(
  initialLocation: '/overview',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          HomeShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [GoRoute(path: '/overview', builder: (c, s) => const OverviewPage())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/accounts', builder: (c, s) => const AccountsPage())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/investment', builder: (c, s) => const InvestmentPage())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/liabilities', builder: (c, s) => const LiabilitiesPage())],
        ),
      ],
    ),
    GoRoute(path: '/ai-review', builder: (c, s) => const AiReviewPage()),
    GoRoute(path: '/ai-import/text', builder: (c, s) => const AiImportTextPage()),
    GoRoute(path: '/accounts/new', builder: (c, s) => const AccountFormPage()),
    GoRoute(
      path: '/account/:id',
      builder: (c, s) => AccountDetailPage(accountId: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/account/:id/edit',
      builder: (c, s) => AccountFormPage(existing: s.extra as AccountVm?),
    ),
    GoRoute(path: '/record/manual', builder: (c, s) => const ManualRecordPage()),
    GoRoute(path: '/anomalies', builder: (c, s) => const AnomaliesPage()),
    GoRoute(path: '/snapshots', builder: (c, s) => const SnapshotsPage()),
    GoRoute(path: '/settings', builder: (c, s) => const SettingsPage()),
    GoRoute(
      path: '/movement/:id',
      builder: (c, s) => MovementDetailPage(movementId: s.pathParameters['id']!),
    ),
    GoRoute(path: '/dev/tokens', builder: (c, s) => const _TokensPreviewRoute()),
  ],
);

/// 把 dev token 预览接到 themeModeProvider（保留深/浅切换）。
class _TokensPreviewRoute extends ConsumerWidget {
  const _TokensPreviewRoute();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final isDark = mode == ThemeMode.dark ||
        (mode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    return TokensPreview(
      isDark: isDark,
      onToggleTheme: () => ref.read(themeModeProvider.notifier).toggle(),
    );
  }
}
