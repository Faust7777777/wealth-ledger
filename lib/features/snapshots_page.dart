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

  Future<void> _createSnapshot(
    BuildContext context,
    WidgetRef ref,
    String reason,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(snapshotRepositoryProvider)
          .createManualSnapshot(reason: reason);
      ref.invalidate(snapshotsProvider);
      ref.invalidate(overviewProvider);
      messenger.showSnackBar(const SnackBar(content: Text('快照已创建')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(snapshotsProvider);
    final snapshots = async.asData?.value;
    final reason = (snapshots == null || snapshots.isEmpty)
        ? 'baseline'
        : 'manual_refresh';
    return Scaffold(
      appBar: AppBar(
        title: const Text('快照历史'),
        actions: [
          IconButton(
            tooltip: snapshots == null ? '创建快照' : '创建当前快照',
            onPressed: snapshots == null
                ? null
                : () => _createSnapshot(context, ref, reason),
            icon: const Icon(Icons.add_chart_outlined),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorStateView(
          message: '$e',
          onRetry: () => ref.invalidate(snapshotsProvider),
        ),
        data: (snaps) {
          if (snaps.isEmpty) {
            return EmptyState(
              icon: Icons.history,
              title: '暂无快照',
              message: '创建第一条基线快照后，净值历史会在这里按时间列出。',
              action: FilledButton(
                onPressed: () => _createSnapshot(context, ref, 'baseline'),
                child: const Text('创建基线快照'),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.base),
            itemCount: snaps.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = snaps[i];
              final est =
                  s.quality == ValueQuality.estimated ||
                  s.quality == ValueQuality.incomplete;
              return ListTile(
                title: Text(
                  '${est ? '≈ ' : ''}${formatMoney(s.netWorth)}',
                  style: AppType.moneyRow,
                ),
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
