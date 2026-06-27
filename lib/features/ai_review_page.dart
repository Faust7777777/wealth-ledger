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
        error: (e, _) =>
            ErrorStateView(message: '$e', onRetry: () => ref.invalidate(aiPendingProvider)),
        data: (proposals) {
          if (proposals.isEmpty) {
            return const EmptyState(
              icon: Icons.inbox_outlined,
              title: '没有待确认的 AI 提案',
              message: 'AI 导入或修改会先进入这里，逐组确认后才写入账本。',
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
            Text(p.summary ?? 'AI 提案', style: Theme.of(context).textTheme.titleMedium),
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Chip(
                label: Text(_opLabel),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                onPressed: () => _run(
                  context,
                  ref,
                  () => ref.read(aiProposalRepositoryProvider).rejectAtomicGroup(g.id),
                  '已拒绝该组',
                  writesLedger: false,
                ),
                child: const Text('拒绝整组'),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => context.push('/ai-edit/${g.id}'),
                child: const Text('编辑'),
              ),
              const SizedBox(width: AppSpacing.sm),
              FilledButton(
                onPressed: () => _run(
                  context,
                  ref,
                  () => ref.read(aiProposalRepositoryProvider).approveAtomicGroup(g.id),
                  '已接受该组',
                  writesLedger: true,
                ),
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
    Future<void> Function() op,
    String okMsg, {
    required bool writesLedger,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await op();
      ref.invalidate(aiPendingProvider);
      if (writesLedger) {
        // 接受 = confirm：已写入正式账本，刷新所有账本派生视图。
        ref.invalidate(overviewProvider);
        ref.invalidate(accountsProvider);
        ref.invalidate(recentMovementsProvider);
        ref.invalidate(allocationProvider);
        ref.invalidate(snapshotsProvider);
      }
      messenger.showSnackBar(
        SnackBar(content: Text(writesLedger ? '$okMsg · 已入账' : '$okMsg（未写账本）')),
      );
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
        AiDiffSeverity.important => dark ? AppColors.warningText : AppColorsLight.warning,
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
            child: Text(d.oldValue ?? '—',
                style: AppType.caption.copyWith(
                    decoration: d.changed ? TextDecoration.lineThrough : null)),
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
