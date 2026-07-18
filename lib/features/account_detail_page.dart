// Wealth Ledger — 账户详情（账户视角：该账户名下持仓）。
// 只读、fixture 驱动；与投资页（资产视角）是同一份 holding 数据的两种投影。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'account_visuals.dart';
import 'holding_adjustment_dialog.dart';

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
          // 账户写能力由服务端 capabilities 决定；只读时禁用编辑/归档。
          if (acct != null)
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: ref.writeCapabilities.canCreateAccount
                  ? () => context.push('/account/${acct.id}/edit', extra: acct)
                  : null,
            ),
          IconButton(
            tooltip: '归档',
            icon: const Icon(Icons.archive_outlined),
            onPressed: ref.writeCapabilities.canCreateAccount
                ? () => _archive(context, ref)
                : null,
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
            // 账户是资产容器：现金/稳定币与持仓分组展示，原始数量为主。
            final holdingsCapable =
                !a.isLiability &&
                (a.balanceMode == 'holdings' || a.balanceMode == 'mixed');
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.base),
              children: [
                _Header(a: a),
                if (a.cashBalances.isNotEmpty) ...[
                  SectionHeader(title: a.isLiability ? '欠款明细' : '现金与稳定币'),
                  for (final e in a.cashBalances.entries)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(e.key),
                      // 负债余额按语义展示（绝对值+标签），不出现账本负号。
                      trailing: a.isLiability
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  liabilityBalanceText(e.value, e.key),
                                  style: AppType.moneyRow,
                                ),
                                Text(
                                  liabilityAmountLabel(e.value),
                                  style: AppType.caption,
                                ),
                              ],
                            )
                          // 原始数量为主信息，不折算、不加币种符号。
                          : Text(
                              formatDecimalThousands(e.value),
                              style: AppType.moneyRow,
                            ),
                    ),
                ],
                if (holdingsCapable || holdings.isNotEmpty) ...[
                  SectionHeader(
                    title: '持仓',
                    trailing: holdingsCapable
                        ? TextButton.icon(
                            onPressed:
                                ref.writeCapabilities.canPersistPendingProposal
                                ? () => showHoldingAdjustmentDialog(
                                    context,
                                    account: a,
                                  )
                                : null,
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('添加资产'),
                          )
                        : null,
                  ),
                  if (holdings.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.sm,
                      ),
                      child: Text(
                        '暂无持仓',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  else
                    for (final h in holdings) _HoldingTile(h: h, account: a),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _archive(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('归档账户'),
        content: const Text('归档后不能用于新记录。确认归档？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('归档'),
          ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(accountTypeIcon(a.accountType)),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                a.displayName,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(sub, style: AppType.caption),
        const SizedBox(height: AppSpacing.sm),
        // 账户估值与净值 Hero 同一处理：真实值之间过渡，不伪造中间金额。
        // 负债账户按语义展示（绝对值+标签），不出现账本负号。
        AnimatedMoneyText(
          v == null
              ? '—'
              : a.isLiability
              ? liabilityValuedText(v)
              : formatValued(v),
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        // 账户总值必须带估值时间；质量由 ≈ / — 前缀表达。
        if (v != null)
          Text(
            '截至 ${v.asOf.replaceFirst('T', ' ').split('.').first}',
            style: AppType.caption,
          ),
        if (a.isLiability && v != null)
          Text(liabilityAmountLabel(v.amount), style: AppType.caption),
      ],
    );
  }
}

class _HoldingTile extends ConsumerWidget {
  const _HoldingTile({required this.h, required this.account});
  final HoldingVm h;
  final AccountVm account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mv = h.marketValue;
    final cost = h.costBasisTotal == null
        ? ''
        : '成本 ${formatMoney(h.costBasisTotal!)}';
    String pnl = '';
    Color? color;
    final p = h.unrealizedPnl;
    if (p != null) {
      final down = p.amount.startsWith('-');
      final abs = p.amount.replaceFirst(RegExp(r'^[+-]'), '');
      pnl = '浮 ${down ? '−' : '+'}¥${formatDecimalThousands(abs)}';
      color = down
          ? (dark ? AppColors.negative : AppColorsLight.negative)
          : (dark ? AppColors.positive : AppColorsLight.positive);
    }
    final sub = pnl.isEmpty ? cost : (cost.isEmpty ? pnl : '$cost   $pnl');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: LeadingAvatar.mono(h.symbol),
      title: Text('${h.displayName} · ${h.symbol}', style: AppType.bodyStrong),
      subtitle: sub.isEmpty
          ? null
          : Text(sub, style: AppType.caption.copyWith(color: color)),
      // 原始数量为主信息；缺报价只弱化折算金额，绝不显示成 0。
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(formatDecimalThousands(h.quantity), style: AppType.moneyRow),
          Text(mv == null ? '暂无估值' : formatValued(mv), style: AppType.caption),
        ],
      ),
      onTap: ref.writeCapabilities.canPersistPendingProposal
          ? () => showHoldingAdjustmentDialog(
              context,
              account: account,
              existing: h,
            )
          : null,
    );
  }
}
