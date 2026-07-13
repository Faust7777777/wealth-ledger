// Wealth Ledger — 订阅列表（近期扣费区 + 全部订阅 + 到期扫描入口）。
// 只读浏览人人可见；创建/扫描等写入口由 canManageSubscriptions 门控。
// 到期扫描是用户显式触发的命令（无后台 timer），只生成待确认候选，不自动确认或扣款。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'subscription_visuals.dart';

class SubscriptionsPage extends ConsumerWidget {
  const SubscriptionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subsAsync = ref.watch(subscriptionsProvider);
    final canManage = ref.writeCapabilities.canManageSubscriptions;
    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅管理'),
        actions: [
          const _DueScanAction(),
          IconButton(
            tooltip: canManage ? '新建订阅' : kReadOnlyHint,
            icon: const Icon(Icons.add),
            onPressed: canManage
                ? () => context.push('/subscriptions/new')
                : null,
          ),
        ],
      ),
      body: ContentMaxWidth(
        child: subsAsync.when(
          loading: () => const ListSkeleton(),
          error: (e, _) => ErrorStateView(
            message: '$e',
            onRetry: () => ref.invalidate(subscriptionsProvider),
          ),
          data: (subs) {
            if (subs.isEmpty) {
              return EmptyState(
                icon: Icons.subscriptions_outlined,
                title: '还没有订阅',
                message:
                    '把 ChatGPT、Claude 等周期扣费登记进来，'
                    '每期到点提醒你生成待确认扣费。',
                action: canManage
                    ? FilledButton.icon(
                        onPressed: () => context.push('/subscriptions/new'),
                        icon: const Icon(Icons.add),
                        label: const Text('新建订阅'),
                      )
                    : Text(
                        kReadOnlyHint,
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
              );
            }
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.base),
              children: [
                const _UpcomingSection(),
                const SectionHeader(title: '全部订阅'),
                for (final s in subs) _SubscriptionTile(sub: s),
                const SizedBox(height: AppSpacing.xl),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 「扫描到期扣费」AppBar 动作：用户显式触发，busy 期间禁点防重复。
class _DueScanAction extends ConsumerStatefulWidget {
  const _DueScanAction();

  @override
  ConsumerState<_DueScanAction> createState() => _DueScanActionState();
}

class _DueScanActionState extends ConsumerState<_DueScanAction> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final canManage = ref.writeCapabilities.canManageSubscriptions;
    return IconButton(
      tooltip: canManage ? '扫描到期扣费' : kReadOnlyHint,
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.manage_search),
      onPressed: _busy || !canManage ? null : _scan,
    );
  }

  Future<void> _scan() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    // 失效前取列表快照，供结果里把 subscriptionId 映射为名称。
    final names = {
      for (final s
          in ref.read(subscriptionsProvider).asData?.value ??
              const <SubscriptionVm>[])
        s.id: s.displayName,
    };
    try {
      var again = true;
      while (again && mounted) {
        final SubscriptionDueScanResultVm result;
        try {
          result = await ref
              .read(subscriptionRepositoryProvider)
              .scanDueChargeProposals(throughDate: todayIsoDate());
          ref.refreshAfterDueScan();
        } finally {
          // spinner 只覆盖请求阶段；结果对话框打开期间不显示进行中。
          if (mounted) setState(() => _busy = false);
        }
        if (!mounted) return;
        // 返回 true 表示用户选了「再次扫描」（hasMore 时提供）。
        again =
            (await showDialog<bool>(
              context: context,
              builder: (_) =>
                  DueScanResultDialog(result: result, subscriptionNames: names),
            )) ??
            false;
        if (again && mounted) setState(() => _busy = true);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// 到期扫描结果：只报告候选生成情况（待确认语义），绝不出现「已扣款/已入账」。
/// pop(true) 表示用户要求再次扫描。公开以便 golden 预览直接渲染。
class DueScanResultDialog extends StatelessWidget {
  const DueScanResultDialog({
    super.key,
    required this.result,
    this.subscriptionNames = const {},
  });

  final SubscriptionDueScanResultVm result;

  /// subscriptionId → displayName（来自扫描前的列表快照；缺失时回退显示 id）。
  final Map<String, String> subscriptionNames;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = result;
    final blocked = [
      for (final s in r.skipped)
        if (s.reason != SubscriptionDueScanSkipReason.alreadyPending) s,
    ];
    return AlertDialog(
      title: const Text('到期扫描结果'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (r.createdCount > 0) ...[
                Text(
                  '已生成 ${r.createdCount} 个待确认扣费',
                  style: t.textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text('确认后才会入账；不代表已向服务商实际扣款。', style: t.textTheme.bodySmall),
              ] else
                Text(
                  r.skipped.isEmpty && !r.hasMore
                      ? '截至 ${r.throughDate} 没有需要生成的到期扣费。'
                      : '本次没有生成新的扣费候选。',
                  style: t.textTheme.bodyMedium,
                ),
              if (r.alreadyPendingCount > 0) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '已在审核队列 ${r.alreadyPendingCount} 个：此前生成的候选还未处理，无需重复生成。',
                  style: t.textTheme.bodySmall,
                ),
              ],
              if (blocked.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                Text('受阻 ${r.blockedCount} 个', style: t.textTheme.titleSmall),
                for (final s in blocked)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(
                      '${subscriptionNames[s.subscriptionId] ?? s.subscriptionId}'
                      ' · 计划 ${s.scheduledChargeDate}\n'
                      '${dueScanSkipReasonLabel(s.reason)}',
                      style: t.textTheme.bodySmall,
                    ),
                  ),
              ],
              if (r.hasMore) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '还有 ${r.remainingEligibleCount} 个到期订阅本次未生成（单次上限），可再次扫描。',
                  style: t.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('关闭'),
        ),
        if (r.hasMore)
          OutlinedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('再次扫描'),
          ),
        if (r.createdCount > 0)
          FilledButton(
            onPressed: () {
              final router = GoRouter.of(context);
              Navigator.pop(context, false);
              router.push('/ai-review');
            },
            child: const Text('前往审核'),
          ),
      ],
    );
  }
}

/// 近期扣费区：逾期优先，暖琥珀提示（不用危险色制造恐慌）。
class _UpcomingSection extends ConsumerWidget {
  const _UpcomingSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final upcoming = ref.watch(upcomingSubscriptionsProvider).asData?.value;
    if (upcoming == null || upcoming.isEmpty) return const SizedBox.shrink();
    final today = todayIsoDate();
    final sorted = [...upcoming]
      ..sort((a, b) {
        final ad = a.nextChargeDate ?? '9999-12-31';
        final bd = b.nextChargeDate ?? '9999-12-31';
        return ad.compareTo(bd);
      });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: '近期扣费'),
        for (final s in sorted) _UpcomingTile(sub: s, today: today),
      ],
    );
  }
}

class _UpcomingTile extends StatelessWidget {
  const _UpcomingTile({required this.sub, required this.today});
  final SubscriptionVm sub;
  final String today;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final overdue = isOverdueChargeDate(sub.nextChargeDate, today: today);
    final accent = subscriptionStatusColor(
      overdue ? SubscriptionStatus.paused : sub.status, // 逾期用琥珀 warning
      dark: dark,
    );
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: () => context.push('/subscriptions/${sub.id}'),
      leading: LeadingAvatar.icon(
        overdue ? Icons.schedule : Icons.event_available_outlined,
      ),
      title: Text(sub.displayName),
      subtitle: Text(
        sub.nextChargeDate == null
            ? '未排期'
            : overdue
            ? '已逾期 · 计划 ${sub.nextChargeDate}'
            : '下次扣费 ${sub.nextChargeDate}',
        style: t.textTheme.bodySmall?.copyWith(color: accent),
      ),
      trailing: Text(
        formatMoney(sub.amount, withCode: true),
        style: AppType.moneyRow,
      ),
    );
  }
}

class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({required this.sub});
  final SubscriptionVm sub;

  @override
  Widget build(BuildContext context) {
    final cycle = billingCycleLabel(sub.billingCycle);
    final next = sub.nextChargeDate == null
        ? '未排期'
        : '下次 ${sub.nextChargeDate}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: () => context.push('/subscriptions/${sub.id}'),
      leading: LeadingAvatar.mono(sub.provider),
      title: Text(sub.displayName),
      subtitle: Text(
        '${sub.provider} · $cycle · $next',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            formatMoney(sub.amount, withCode: true),
            style: AppType.moneyRow,
          ),
          const SizedBox(height: AppSpacing.xxs),
          SubscriptionStatusPill(sub.status),
        ],
      ),
    );
  }
}
