// Wealth Ledger — 概览页（L0 净值 → L1 待处理 → L2 主要持仓 → L4 近期变动）。
// 第一阶段：real_local 显空态；debug_fixture 显 DEMO 数据。布局从简，不铺满。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

class OverviewPage extends ConsumerWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(overviewProvider);
    final accounts = ref.watch(accountsProvider).asData?.value ?? const <AccountVm>[];
    final allocation = ref.watch(allocationProvider).asData?.value;
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          ErrorStateView(message: '$e', onRetry: () => ref.invalidate(overviewProvider)),
      data: (o) {
        if (o.isEmpty) {
          return const EmptyState(
            icon: Icons.savings_outlined,
            title: '今天开始记录你的净资产',
            message: '添加账户与初始余额后，这里会显示净值、账户健康与投资表现。',
          );
        }
        return ListView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          children: [
            _Hero(o: o),
            if (o.pendingSummary.total > 0) _Pending(s: o.pendingSummary),
            if (allocation != null && !allocation.isEmpty) _AllocationBar(a: allocation),
            if (o.primaryHoldings.isNotEmpty) ...[
              const SectionHeader(title: '主要持仓'),
              for (final h in o.primaryHoldings) _HoldingRow(h: h),
            ],
            if (accounts.isNotEmpty) ...[
              SectionHeader(
                title: '账户',
                trailing: TextButton(
                  onPressed: () => context.go('/accounts'),
                  child: const Text('全部'),
                ),
              ),
              for (final a in accounts.take(5)) _AccountRow(a: a),
            ],
            if (o.recentMovements.isNotEmpty) ...[
              const SectionHeader(title: '近期变动'),
              for (final m in o.recentMovements) _MovementRow(m: m),
            ],
          ],
        );
      },
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.o});
  final PortfolioOverviewVm o;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final snap = o.latestSnapshot;
    final muted = Theme.of(context).textTheme.bodySmall;
    final estimated = snap != null &&
        (snap.quality == ValueQuality.estimated ||
            snap.quality == ValueQuality.incomplete);
    final amount = snap == null
        ? '—'
        : '${estimated ? '≈ ' : ''}${formatMoney(snap.netWorth)}';

    final change = o.changeSinceLastSnapshot;
    Widget? deltaLine;
    if (change != null) {
      final down = change.amount.startsWith('-');
      final abs = change.amount.replaceFirst(RegExp(r'^[+-]'), '');
      final label = o.quoteStatusSummary.allFresh ? '今日' : '较上次快照';
      final color =
          down ? (dark ? AppColors.negative : AppColorsLight.negative) : (dark ? AppColors.positive : AppColorsLight.positive);
      deltaLine = Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xs),
        child: Text('${down ? '▼' : '▲'} ¥${formatDecimalThousands(abs)}  $label',
            style: AppType.body.copyWith(color: color)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('净资产 · CNY', style: muted),
        const SizedBox(height: AppSpacing.sm),
        Text(amount, style: Theme.of(context).textTheme.displayLarge),
        ?deltaLine,
        if (!o.quoteStatusSummary.allFresh)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text(
              '◐ ${o.quoteStatusSummary.staleCount} 项报价过期 · 本地缓存',
              style: AppType.caption.copyWith(
                  color: dark ? AppColors.warningText : AppColorsLight.warning),
            ),
          ),
      ],
    );
  }
}

class _Pending extends StatelessWidget {
  const _Pending({required this.s});
  final PendingSummaryVm s;

  @override
  Widget build(BuildContext context) {
    final items = <(String, int, String?)>[
      ('AI 待确认', s.aiPendingCount, '/ai-review'),
      ('账户异常', s.accountAnomalyCount, '/anomalies'),
      ('定投到期', s.dcaDueCount, '/investment'),
      ('在途交易', s.inTransitCount, null),
      ('报价问题', s.quoteProblemCount, null),
      ('同步降级', s.syncProblemCount, null),
    ].where((e) => e.$2 > 0).toList();

    return Card(
      margin: const EdgeInsets.only(top: AppSpacing.xl),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.base),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('待处理 (${s.total})', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            for (final e in items)
              InkWell(
                onTap: e.$3 == null
                    ? null
                    : () => e.$3 == '/investment' ? context.go(e.$3!) : context.push(e.$3!),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Row(
                    children: [
                      Expanded(child: Text(e.$1, style: AppType.body)),
                      Text('${e.$2}', style: AppType.bodyStrong),
                      Icon(Icons.chevron_right,
                          size: 18, color: e.$3 == null ? Colors.transparent : null),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HoldingRow extends StatelessWidget {
  const _HoldingRow({required this.h});
  final HoldingVm h;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mv = h.marketValue;
    final value = mv == null ? '—' : formatValued(mv);
    String pnl = '';
    Color? pnlColor;
    final p = h.unrealizedPnl;
    if (p != null) {
      final down = p.amount.startsWith('-');
      final abs = p.amount.replaceFirst(RegExp(r'^[+-]'), '');
      pnl = '浮 ${down ? '−' : '+'}¥${formatDecimalThousands(abs)}';
      pnlColor = down
          ? (dark ? AppColors.negative : AppColorsLight.negative)
          : (dark ? AppColors.positive : AppColorsLight.positive);
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text('${h.symbol} · ${h.quantity}', style: AppType.bodyStrong),
      subtitle: pnl.isEmpty ? null : Text(pnl, style: AppType.caption.copyWith(color: pnlColor)),
      trailing: Text(value, style: AppType.moneyRow),
    );
  }
}

class _MovementRow extends StatelessWidget {
  const _MovementRow({required this.m});
  final MovementVm m;

  @override
  Widget build(BuildContext context) {
    final amt = m.displayAmount;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(m.title, style: AppType.body),
      subtitle: m.inTransit
          ? Text('在途 · 非支出', style: AppType.caption)
          : null,
      trailing: amt == null ? null : Text(formatMoney(amt), style: AppType.moneyRow),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.a});
  final AccountVm a;

  @override
  Widget build(BuildContext context) {
    final v = a.value;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(a.displayName, style: AppType.body),
      trailing: Text(v == null ? '—' : formatValued(v), style: AppType.moneyRow),
      onTap: () => context.push('/account/${a.id}'),
    );
  }
}

class _AllocationBar extends StatelessWidget {
  const _AllocationBar({required this.a});
  final AssetAllocationVm a;

  static const List<Color> _palette = [
    Color(0xFF7FA88B), // sage
    Color(0xFF6E8DA8), // slate
    Color(0xFF8E86B3), // iris
    Color(0xFFCBB079), // champagne
    Color(0xFFB07BA0), // plum
    Color(0xFF857D72), // warm gray
  ];

  int _flex(String pct) {
    final v = double.tryParse(pct) ?? 0; // 仅用于布局权重，非金额运算
    final f = (v * 10).round();
    return f < 1 ? 1 : f;
  }

  @override
  Widget build(BuildContext context) {
    final slices = a.slices;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: '资产构成'),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: SizedBox(
            height: 12,
            child: Row(
              children: [
                for (var i = 0; i < slices.length; i++)
                  Expanded(
                    flex: _flex(slices[i].percent),
                    child: Container(color: _palette[i % _palette.length]),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.base,
          runSpacing: AppSpacing.xs,
          children: [
            for (var i = 0; i < slices.length; i++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _palette[i % _palette.length],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text('${slices[i].category} ${slices[i].percent}%', style: AppType.caption),
                ],
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '− 负债 ${formatMoney(a.totalLiabilities)} → 净 ${formatMoney(a.netWorth)}',
          style: AppType.caption,
        ),
      ],
    );
  }
}
