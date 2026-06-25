// Wealth Ledger — 快照历史（概览二级入口；read-only / fixture）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/types.dart';
import '../data/providers.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

class SnapshotsPage extends ConsumerWidget {
  const SnapshotsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(snapshotsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('快照历史')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorStateView(
          message: '$e',
          onRetry: () => ref.invalidate(snapshotsProvider),
        ),
        data: (snaps) {
          if (snaps.isEmpty) {
            return const EmptyState(
              icon: Icons.history,
              title: '暂无快照',
              message: '净值快照会在这里按时间列出（含降级日标注）。',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.base),
            itemCount: snaps.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = snaps[i];
              final est = s.quality == ValueQuality.estimated ||
                  s.quality == ValueQuality.incomplete;
              return ListTile(
                title: Text('${est ? '≈ ' : ''}${formatMoney(s.netWorth)}',
                    style: AppType.moneyRow),
                subtitle: Text(s.snapshotAt.split('T').first),
                trailing: Text(est ? '估算' : '精确', style: AppType.caption),
              );
            },
          );
        },
      ),
    );
  }
}
