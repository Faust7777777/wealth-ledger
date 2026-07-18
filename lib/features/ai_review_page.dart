// Wealth Ledger — AI 复核页（候选 → 逐组确认；改已有记录显示 old → new diff）。
// 强约束：最小确认单位=atomic_group；整组接受或整组拒绝；确认前不进余额/流水/净值。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

class AiReviewPage extends ConsumerWidget {
  const AiReviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(aiPendingProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('AI 待确认')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorStateView(
          message: '$e',
          onRetry: () => ref.invalidate(aiPendingProvider),
        ),
        data: (proposals) {
          if (proposals.isEmpty) {
            return const EmptyState(
              icon: Icons.inbox_outlined,
              title: '没有待确认项',
            );
          }
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.base),
            children: [for (final p in proposals) _ProposalCard(p: p)],
          );
        },
      ),
    );
  }
}

class _ProposalCard extends StatelessWidget {
  const _ProposalCard({required this.p});
  final AiProposalVm p;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.base),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.base),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              p.summary ?? 'AI 提案',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text('来源：${p.sourceLabel}', style: AppType.caption),
            const Divider(),
            for (final g in p.groups) _GroupBlock(g: g),
          ],
        ),
      ),
    );
  }
}

class _GroupBlock extends ConsumerWidget {
  const _GroupBlock({required this.g});
  final AiAtomicGroupVm g;

  String get _opLabel => switch (g.operation) {
    AiOperation.create => '新增',
    AiOperation.modify => '修改',
    AiOperation.correction => '更正',
    AiOperation.merge => '归并',
    AiOperation.classify => '分类',
  };

  // 操作语义色：新增=绿 / 修改=蓝 / 更正=琥珀 / 归并=鸢尾 / 分类=金。
  Color _opColor(bool dark) => switch (g.operation) {
    AiOperation.create => dark ? AppColors.positive : AppColorsLight.positive,
    AiOperation.modify => dark ? AppColors.info : AppColorsLight.info,
    AiOperation.correction => dark ? AppColors.warning : AppColorsLight.warning,
    AiOperation.merge => dark ? AppColors.inTransit : AppColorsLight.inTransit,
    AiOperation.classify => dark ? AppColors.brand : AppColorsLight.brand,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final opColor = _opColor(dark);
    final surface = dark ? AppColors.surface2 : AppColorsLight.surface2;
    // 每个 atomic group 框成独立子面板：强化「逐组确认」的最小单元感。
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: Theme.of(context).dividerColor,
          width: AppStroke.hairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: opColor.withValues(alpha: dark ? 0.18 : 0.14),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text(
                  _opLabel,
                  style: AppType.micro.copyWith(
                    color: opColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(g.title, style: AppType.bodyStrong)),
            ],
          ),
          if (g.diffs.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            for (final d in g.diffs) _DiffRow(d: d),
          ],
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              TextButton(
                onPressed: () => _run(context, ref, () async {
                  await ref
                      .read(aiProposalRepositoryProvider)
                      .rejectAtomicGroup(g.id);
                  return null;
                }, '已拒绝该组'),
                child: const Text('拒绝整组'),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => context.push('/ai-edit/${g.id}'),
                child: const Text('编辑'),
              ),
              const SizedBox(width: AppSpacing.sm),
              FilledButton(
                // 确认能力由服务端 capabilities 决定；不可确认时禁用。
                onPressed: ref.writeCapabilities.canConfirmProposal
                    ? () => _run(
                        context,
                        ref,
                        () => ref
                            .read(aiProposalRepositoryProvider)
                            .approveAtomicGroup(g.id),
                        '已接受该组',
                      )
                    : null,
                child: const Text('接受整组'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<ConfirmResultVm?> Function() op,
    String okMsg,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await op();
      ref.invalidate(aiPendingProvider);
      // 该组可能是订阅扣费候选：确认或拒绝后订阅 pending/nextCharge 都会变，一并刷新。
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(upcomingSubscriptionsProvider);
      final shouldRefreshLedgerViews =
          result?.ledgerWrite == true || result?.snapshotInvalidated == true;
      if (shouldRefreshLedgerViews) {
        // 只消费服务端确认结果：ledgerWrite/snapshotInvalidated 为真才刷新账本派生视图。
        ref.invalidate(overviewProvider);
        ref.invalidate(accountsProvider);
        ref.invalidate(liabilitiesProvider);
        ref.invalidate(holdingsProvider);
        ref.invalidate(recentMovementsProvider);
        ref.invalidate(allocationProvider);
        ref.invalidate(snapshotsProvider);
        ref.invalidate(anomaliesProvider);
      }
      final suffix = result == null
          ? ''
          : result.ledgerWrite
          ? ' · 已入账'
          : '（尚未入账）';
      messenger.showSnackBar(SnackBar(content: Text('$okMsg$suffix')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.d});
  final AiFieldDiffVm d;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    Color? newColor;
    if (d.changed) {
      newColor = switch (d.severity) {
        AiDiffSeverity.danger => dark ? AppColors.error : AppColorsLight.error,
        AiDiffSeverity.important =>
          dark ? AppColors.warningText : AppColorsLight.warning,
        AiDiffSeverity.normal => null,
      };
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 64, child: Text(d.fieldPath, style: AppType.caption)),
          Expanded(
            child: Text(
              d.oldValue ?? '—',
              style: AppType.caption.copyWith(
                decoration: d.changed ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: Icon(Icons.arrow_forward, size: 14),
          ),
          Expanded(
            child: Text(
              d.newValue ?? '—',
              style: (d.changed ? AppType.bodyStrong : AppType.caption)
                  .copyWith(color: newColor),
            ),
          ),
        ],
      ),
    );
  }
}
