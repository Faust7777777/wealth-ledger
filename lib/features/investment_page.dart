// Wealth Ledger — 投资页（资产视角：主要持仓 + 定投提醒）。
// 持仓为事实统计（成本/市值/浮盈亏），不做投资建议。定投只提醒，不下单。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

class InvestmentPage extends ConsumerWidget {
  const InvestmentPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final holdings = ref.watch(holdingsProvider);
    final reminders = ref.watch(dueRemindersProvider);

    return holdings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          ErrorStateView(message: '$e', onRetry: () => ref.invalidate(holdingsProvider)),
      data: (hs) {
        final rs = reminders.asData?.value ?? const <DcaReminderVm>[];
        if (hs.isEmpty && rs.isEmpty) {
          return const EmptyState(
            icon: Icons.trending_up_outlined,
            title: '还没有投资持仓',
            message: '添加券商 / 交易所账户与持仓后，这里显示市值与浮盈亏（事实统计，非投资建议）。',
          );
        }
        return ListView(
          padding: const EdgeInsets.all(AppSpacing.base),
          children: [
            if (hs.isNotEmpty) ...[
              const SectionHeader(title: '主要持仓'),
              for (final h in hs) _HoldingTile(h: h),
            ],
            const SectionHeader(title: '定投提醒'),
            if (rs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Text('暂无到期定投', style: Theme.of(context).textTheme.bodySmall),
              )
            else
              for (final r in rs) _ReminderTile(r: r),
          ],
        );
      },
    );
  }
}

class _HoldingTile extends StatelessWidget {
  const _HoldingTile({required this.h});
  final HoldingVm h;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cost = h.costBasisTotal == null ? '成本未记录' : '成本 ${formatMoney(h.costBasisTotal!)}';
    final mv = h.marketValue;
    String pnl = '';
    Color? color;
    final p = h.unrealizedPnl;
    if (p != null) {
      final down = p.amount.startsWith('-');
      final abs = p.amount.replaceFirst(RegExp(r'^[+-]'), '');
      final rate = h.unrealizedPnlRate;
      pnl = '浮 ${down ? '−' : '+'}¥${formatDecimalThousands(abs)}'
          '${rate == null ? '' : '  ${_pct(rate)}'}';
      color = down
          ? (dark ? AppColors.negative : AppColorsLight.negative)
          : (dark ? AppColors.positive : AppColorsLight.positive);
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${h.displayName} · ${h.symbol} · ${h.quantity}', style: AppType.bodyStrong),
      subtitle: Text(
        pnl.isEmpty ? cost : '$cost   $pnl',
        style: AppType.caption.copyWith(color: color),
      ),
      trailing: Text(mv == null ? '—' : formatValued(mv), style: AppType.moneyRow),
    );
  }

  String _pct(String rate) {
    // rate 为小数字符串（如 0.0518）→ 估算百分比展示；不参与金额运算。
    final neg = rate.startsWith('-');
    final body = rate.replaceFirst(RegExp(r'^[+-]'), '');
    return '${neg ? '−' : '+'}$body 率';
  }
}

class _ReminderTile extends StatelessWidget {
  const _ReminderTile({required this.r});
  final DcaReminderVm r;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.event_repeat_outlined),
      title: Text(r.displayName),
      subtitle: Text('每期 ${formatMoney(r.plannedAmount)} · 下次 ${r.dueDate}'),
      trailing: OutlinedButton(
        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('记录已执行：生成候选记录（不下单 / 不转账），确认后入账')),
        ),
        child: const Text('记录已执行'),
      ),
    );
  }
}
