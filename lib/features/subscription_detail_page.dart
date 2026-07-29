// Wealth Ledger — 订阅详情：计划信息 + 上/下期 + 待确认候选 + 动作。
// 「记录本期扣费」只生成 pending_review 候选；确认前不动余额。取消只停未来排期，
// 不向服务商发起真实退订。所有写动作由 canManageSubscriptions 门控。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../data/api_mock_repositories.dart' show ApiConflictException;
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'subscription_visuals.dart';

class SubscriptionDetailPage extends ConsumerWidget {
  const SubscriptionDetailPage({super.key, required this.subscriptionId});
  final String subscriptionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(subscriptionByIdProvider(subscriptionId));
    final canManage = ref.writeCapabilities.canManageSubscriptions;
    final sub = async.asData?.value;
    return Scaffold(
      appBar: AppBar(
        title: Text(sub?.displayName ?? '订阅详情'),
        actions: [
          if (sub != null)
            IconButton(
              tooltip: canManage ? '编辑' : kReadOnlyHint,
              icon: const Icon(Icons.edit_outlined),
              onPressed: canManage
                  ? () => context.push(
                      '/subscriptions/${sub.id}/edit',
                      extra: sub,
                    )
                  : null,
            ),
        ],
      ),
      body: ContentMaxWidth(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) {
            if ('$e'.contains('404')) {
              return EmptyState(
                icon: Icons.help_outline,
                title: '订阅不存在',
                message: '它可能已被删除。',
                action: FilledButton(
                  onPressed: () => context.go('/subscriptions'),
                  child: const Text('返回列表'),
                ),
              );
            }
            return ErrorStateView(
              message: '$e',
              onRetry: () =>
                  ref.invalidate(subscriptionByIdProvider(subscriptionId)),
            );
          },
          data: (s) => _Body(sub: s, canManage: canManage),
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.sub, required this.canManage});
  final SubscriptionVm sub;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider).asData?.value;
    final acct = accounts?.cast<AccountVm?>().firstWhere(
      (a) => a!.id == sub.paymentAccountId,
      orElse: () => null,
    );
    final acctLabel = acct?.displayName ?? sub.paymentAccountId;
    final currencyMismatch =
        acct != null && !_accountSupports(acct, sub.amount.currency);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.base),
      children: [
        _Header(sub: sub),
        if (sub.hasPendingCharge) _PendingChargeBanner(sub: sub),
        const SectionHeader(title: '计划信息'),
        _InfoRow('原币金额', formatMoney(sub.amount, withCode: true)),
        _InfoRow('计费周期', billingCycleLabel(sub.billingCycle)),
        _InfoRow('付款账户', currencyMismatch ? '$acctLabel（币种不匹配）' : acctLabel),
        _InfoRow('开始日期', sub.startDate),
        if (sub.duration != null)
          _InfoRow('持续时长', durationLabel(sub.duration!)),
        if (sub.endDate != null) _InfoRow('结束日期', sub.endDate!),
        _InfoRow('自动续订', sub.autoRenew ? '开' : '关'),
        _InfoRow('提前提醒', '${sub.reminderDaysBefore} 天'),
        if (sub.note != null && sub.note!.isNotEmpty) _InfoRow('备注', sub.note!),

        const SectionHeader(title: '扣费情况'),
        _InfoRow('下期扣费', sub.nextChargeDate ?? '未排期'),
        _InfoRow('上期扣费', sub.lastChargeDate ?? '暂无'),
        _InfoRow(
          '待确认扣费',
          sub.hasPendingCharge
              ? '本期已生成（${sub.pendingChargeDate ?? '待确认'}）'
              : '无',
        ),

        const SizedBox(height: AppSpacing.lg),
        WriteGate(
          enabled: canManage,
          child: _Actions(sub: sub),
        ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }

  bool _accountSupports(AccountVm a, String currency) =>
      a.defaultCurrency == currency || a.cashBalances.containsKey(currency);
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.sub});
  final SubscriptionVm sub;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final parts = <String>[
      sub.provider,
      if (sub.planName != null && sub.planName!.isNotEmpty) sub.planName!,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LeadingAvatar.mono(sub.provider, size: 48),
          const SizedBox(width: AppSpacing.base),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(sub.displayName, style: t.textTheme.titleLarge),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  parts.join(' · '),
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                SubscriptionStatusPill(sub.status),
              ],
            ),
          ),
          Text(
            formatMoney(sub.amount, withCode: true),
            style: AppType.moneyRow.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingChargeBanner extends StatelessWidget {
  const _PendingChargeBanner({required this.sub});
  final SubscriptionVm sub;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = dark ? AppColors.info : AppColorsLight.info;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.base),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          Icon(Icons.rate_review_outlined, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '本期已生成待确认扣费${sub.pendingChargeDate == null ? '' : '（${sub.pendingChargeDate}）'}，'
              '尚未入账。',
            ),
          ),
          TextButton(
            onPressed: () => context.push('/ai-review'),
            child: const Text('前往审核'),
          ),
        ],
      ),
    );
  }
}

class _Actions extends ConsumerStatefulWidget {
  const _Actions({required this.sub});
  final SubscriptionVm sub;

  @override
  ConsumerState<_Actions> createState() => _ActionsState();
}

class _ActionsState extends ConsumerState<_Actions> {
  bool _busy = false;

  SubscriptionVm get sub => widget.sub;

  @override
  Widget build(BuildContext context) {
    final canCharge = sub.isSchedulable && !sub.hasPendingCharge;
    // pending 时本地禁用取消（与生成扣费一致）；409 兜底仅处理页面数据过期的竞态。
    final canCancel = sub.isSchedulable && !sub.hasPendingCharge;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: _busy || !canCharge ? null : _recordCharge,
          icon: const Icon(Icons.receipt_long_outlined),
          label: Text(sub.hasPendingCharge ? '本期已有待确认扣费' : '记录本期扣费'),
        ),
        const SizedBox(height: AppSpacing.base),
        OutlinedButton.icon(
          onPressed: _busy || !canCancel ? null : _cancel,
          icon: const Icon(Icons.cancel_outlined),
          label: const Text('取消订阅'),
        ),
      ],
    );
  }

  Future<void> _recordCharge() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(subscriptionRepositoryProvider)
          .createChargeProposal(sub.id);
      ref.refreshAfterChargeProposal(id: sub.id);
      messenger.showSnackBar(
        SnackBar(
          content: const Text('已生成待确认扣费，请到 AI 审核确认'),
          action: SnackBarAction(
            label: '前往审核',
            onPressed: () => context.push('/ai-review'),
          ),
        ),
      );
    } on ApiConflictException {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('本期已有待确认扣费'),
          action: SnackBarAction(
            label: '前往审核',
            onPressed: () => context.push('/ai-review'),
          ),
        ),
      );
      ref.invalidate(subscriptionByIdProvider(sub.id));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('取消订阅'),
        content: const Text('历史记录不受影响。确认取消？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('取消未来扣费'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(subscriptionRepositoryProvider).cancelSubscription(sub.id);
      ref.refreshSubscriptions(id: sub.id);
      messenger.showSnackBar(const SnackBar(content: Text('已取消未来扣费')));
    } on ApiConflictException {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('有待确认扣费，请先在 AI 审核里确认或拒绝，再取消订阅'),
          action: SnackBarAction(
            label: '前往审核',
            onPressed: () => context.push('/ai-review'),
          ),
        ),
      );
      ref.invalidate(subscriptionByIdProvider(sub.id));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
