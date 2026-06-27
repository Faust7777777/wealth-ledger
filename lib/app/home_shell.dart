// Wealth Ledger — 响应式外壳：窄屏底栏(NavigationBar)，宽屏侧栏(NavigationRail)。
// 一级导航 4 项：概览/账户/投资/负债 + 独立 FAB「记录」。
// TODO(icons): 导航暂用 Material 图标占位；最终换 §5.1 自定义图标集。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../features/record_sheet.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';

typedef _Dest = ({IconData icon, IconData selected, String label});

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  static const List<_Dest> _dests = [
    (icon: Icons.dashboard_outlined, selected: Icons.dashboard, label: '概览'),
    (icon: Icons.account_balance_wallet_outlined, selected: Icons.account_balance_wallet, label: '账户'),
    (icon: Icons.trending_up_outlined, selected: Icons.trending_up, label: '投资'),
    (icon: Icons.account_balance_outlined, selected: Icons.account_balance, label: '负债'),
  ];

  void _go(int index) =>
      navigationShell.goBranch(index, initialLocation: index == navigationShell.currentIndex);

  void _refresh(BuildContext context, WidgetRef ref) {
    ref.invalidate(overviewProvider);
    ref.invalidate(accountsProvider);
    ref.invalidate(holdingsProvider);
    ref.invalidate(allocationProvider);
    ref.invalidate(recentMovementsProvider);
    ref.invalidate(snapshotsProvider);
    ref.invalidate(anomaliesProvider);
    ref.invalidate(dueRemindersProvider);
    ref.invalidate(dcaPlansProvider);
    ref.invalidate(aiPendingProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已刷新')),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useRail = MediaQuery.sizeOf(context).width >= AppLayout.bpRailIcon;

    final fab = FloatingActionButton.extended(
      onPressed: () => showRecordSheet(context),
      icon: const Icon(Icons.add),
      label: const Text('记录'),
    );

    final appBar = AppBar(
      title: const Text('Wealth Ledger'),
      actions: [
        IconButton(
          onPressed: () => _refresh(context, ref),
          icon: const Icon(Icons.refresh),
          tooltip: '刷新',
        ),
        IconButton(
          onPressed: () => context.push('/ai-review'),
          icon: const Icon(Icons.reviews_outlined),
          tooltip: 'AI 待确认',
        ),
        IconButton(
          onPressed: () => ref.read(themeModeProvider.notifier).toggle(),
          icon: const Icon(Icons.brightness_6_outlined),
          tooltip: '深 / 浅色',
        ),
        IconButton(
          onPressed: () => context.push('/settings'),
          icon: const Icon(Icons.settings_outlined),
          tooltip: '设置',
        ),
      ],
    );

    if (useRail) {
      return Scaffold(
        appBar: appBar,
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: navigationShell.currentIndex,
              onDestinationSelected: _go,
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: fab,
              ),
              destinations: [
                for (final d in _dests)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selected),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: ContentMaxWidth(child: navigationShell)),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: appBar,
      body: ContentMaxWidth(child: navigationShell),
      floatingActionButton: fab,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: _go,
        destinations: [
          for (final d in _dests)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selected),
              label: d.label,
            ),
        ],
      ),
    );
  }
}
