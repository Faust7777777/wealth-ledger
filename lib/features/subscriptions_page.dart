// Wealth Ledger — 订阅列表（近期扣费区 + 全部订阅）。
// 只读浏览人人可见；创建/编辑等写入口由 canManageSubscriptions 门控。
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
