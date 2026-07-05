// Wealth Ledger — 账户详情（账户视角：该账户名下持仓）。
// 只读、fixture 驱动；与投资页（资产视角）是同一份 holding 数据的两种投影。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/leading_avatar.dart';
import '../shared/money_text.dart';
import '../shared/status_pill.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'account_visuals.dart';

class AccountDetailPage extends ConsumerWidget {
  const AccountDetailPage({super.key, required this.accountId});
  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountAsync = ref.watch(accountByIdProvider(accountId));
    final holdingsAsync = ref.watch(holdingsByAccountProvider(accountId));
    final acct = accountAsync.asData?.value;

    return Scaffold(
      appBar: AppBar(
        title: Text(acct?.displayName ?? '账户详情'),
        actions: [
          if (acct != null)
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push('/account/${acct.id}/edit', extra: acct),
            ),
          IconButton(
            tooltip: '归档',
            icon: const Icon(Icons.archive_outlined),
            onPressed: () => _archive(context, ref),
          ),
        ],
      ),
      body: ContentMaxWidth(
          child: accountAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorStateView(
          message: '$e',
          onRetry: () => ref.invalidate(accountByIdProvider(accountId)),
        ),
        data: (a) {
          if (a == null) {
            return const EmptyState(icon: Icons.help_outline, title: '账户不存在');
          }
          final holdings = holdingsAsync.asData?.value ?? const <HoldingVm>[];
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.base),
            children: [
              _Header(a: a),
              if (a.cashBalances.isNotEmpty) ...[
                const SectionHeader(title: '现金余额'),
                for (final e in a.cashBalances.entries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(e.key),
                    trailing: MoneyText(
                      formatMoney(Money(amount: e.value, currency: e.key)),
                    ),
                  ),
              ],
              if (holdings.isNotEmpty) ...[
                const SectionHeader(title: '持仓'),
                for (final h in holdings) _HoldingTile(h: h),
              ] else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Text(
                    '该账户暂无持仓（现金 / 活期类账户）',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          );
        },
      )),
    );
  }

  Future<void> _archive(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('归档账户'),
        content: const Text('归档后不再计入新记录（后端可恢复）。确认归档？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('归档')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(accountRepositoryProvider).archiveAccount(accountId);
      ref.invalidate(accountsProvider);
      ref.invalidate(overviewProvider);
      messenger.showSnackBar(const SnackBar(content: Text('账户已归档')));
      if (navigator.canPop()) navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.a});
  final AccountVm a;

  @override
  Widget build(BuildContext context) {
    final v = a.value;
    final sub = a.note == null
        ? accountTypeLabel(a.accountType)
        : '${accountTypeLabel(a.accountType)} · ${a.note}';
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.base),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.base),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                LeadingAvatar.icon(accountTypeIcon(a.accountType)),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.displayName, style: AppType.h2),
                      const SizedBox(height: 2),
                      Text(sub, style: AppType.caption),
                    ],
                  ),
                ),
                if (a.isLiability)
                  const StatusPill('负债', tone: StatusTone.negative),
              ],
            ),
            const SizedBox(height: AppSpacing.base),
            MoneyText(
              v == null ? '—' : formatValued(v),
              tone: a.isLiability ? MoneyTone.negative : MoneyTone.normal,
              style: AppType.h1.copyWith(fontSize: 30, fontFeatures: AppType.tnum),
            ),
          ],
        ),
      ),
    );
  }
}

class _HoldingTile extends StatelessWidget {
  const _HoldingTile({required this.h});
  final HoldingVm h;

  @override
  Widget build(BuildContext context) {
    final mv = h.marketValue;
    final cost = h.costBasisTotal == null
        ? '成本未记录'
        : '成本 ${formatMoney(h.costBasisTotal!)}';

    String? pnl;
    var pnlTone = MoneyTone.muted;
    final p = h.unrealizedPnl;
    if (p != null) {
      final down = p.amount.startsWith('-');
      final abs = p.amount.replaceFirst(RegExp(r'^[+-]'), '');
      pnl = '浮 ${down ? '−' : '+'}¥${formatDecimalThousands(abs)}';
      pnlTone = down ? MoneyTone.negative : MoneyTone.positive;
    }

    final sym = h.symbol.trim();
    final mono = sym.isEmpty
        ? '—'
        : (sym.length <= 2 ? sym : sym.substring(0, 2)).toUpperCase();

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: LeadingAvatar.mono(mono),
      title:
          Text('${h.displayName} · ${h.quantity}', style: AppType.bodyStrong),
      subtitle:
          Text(sym.isEmpty ? cost : '$sym · $cost', style: AppType.caption),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          MoneyText.optional(mv == null ? null : formatValued(mv),
              emphasis: true),
          if (pnl != null)
            MoneyText(pnl, tone: pnlTone, style: AppType.caption),
        ],
      ),
    );
  }
}
