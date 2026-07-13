// Wealth Ledger — 响应式外壳：窄屏底栏(NavigationBar)，宽屏侧栏(NavigationRail)。
// 一级导航 4 项：概览/账户/投资/负债 + 独立 FAB「记录」。
// TODO(icons): 导航暂用 Material 图标占位；最终换 §5.1 自定义图标集。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/view_models.dart';
import '../features/record_sheet.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';

typedef _Dest = ({IconData icon, IconData selected, String label});

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  static const List<_Dest> _dests = [
    (icon: Icons.dashboard_outlined, selected: Icons.dashboard, label: '概览'),
    (
      icon: Icons.account_balance_wallet_outlined,
      selected: Icons.account_balance_wallet,
      label: '账户',
    ),
    (
      icon: Icons.trending_up_outlined,
      selected: Icons.trending_up,
      label: '投资',
    ),
    (
      icon: Icons.account_balance_outlined,
      selected: Icons.account_balance,
      label: '负债',
    ),
  ];

  void _go(int index) => navigationShell.goBranch(
    index,
    initialLocation: index == navigationShell.currentIndex,
  );

  String _quoteRefreshMessage(QuoteRefreshResultVm result) {
    final summary = '${result.quoteCount} 项行情 / ${result.fxRateCount} 项汇率';
    final firstError = result.errors.isEmpty ? '' : '：${result.errors.first}';
    return switch (result.status) {
      'success' => '报价已刷新：$summary',
      'partial_success' => '部分报价刷新失败，继续使用缓存$firstError',
      'offline' => '离线或暂无行情接口$firstError',
      'failed' => '报价刷新失败$firstError',
      _ => result.hasProblems ? '报价刷新完成但有问题$firstError' : '报价已刷新：$summary',
    };
  }

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref
          .read(quoteRepositoryProvider)
          .refreshQuotes(mode: 'manual');
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(_quoteRefreshMessage(result))),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('报价刷新失败：$e')));
    }
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
    // 手动刷新兼作 capabilities 重试入口（server 后起时写入口能解锁）。
    ref.invalidate(capabilitiesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final useRail = width >= AppLayout.bpRailIcon;
    // 宽屏（>=1360）用 256px 扩展侧栏（图标+文字横排），否则窄图标栏。
    final extendedRail = width >= AppLayout.bpExpanded;

    // FAB 常显；sheet 内条目按服务端 capabilities 逐项禁用并给出原因。
    final fab = FloatingActionButton.extended(
      onPressed: () => showRecordSheet(context, ref.writeCapabilities),
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
              extended: extendedRail,
              minExtendedWidth: AppLayout.railWidth,
              // 扩展态下标签横排（labelType 须为 none）；窄栏则图标上方显文字。
              labelType: extendedRail
                  ? NavigationRailLabelType.none
                  : NavigationRailLabelType.all,
              leading: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: AppSpacing.md,
                  horizontal: extendedRail ? AppSpacing.base : 0,
                ),
                child: Align(
                  alignment: extendedRail
                      ? Alignment.centerLeft
                      : Alignment.center,
                  child: fab,
                ),
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
