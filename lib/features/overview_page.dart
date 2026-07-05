// Wealth Ledger — 概览页（L0 净值 → L1 待处理 → L2 主要持仓 → L4 近期变动）。
// 第一阶段：real_local 显空态；debug_fixture 显 DEMO 数据。布局从简，不铺满。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/leading_avatar.dart';
import '../shared/money_text.dart';
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
          return EmptyState(
            icon: Icons.savings_outlined,
            title: '今天开始记录你的净资产',
            message: '添加账户与初始余额后，这里会显示净值、账户健康与投资表现。',
            action: FilledButton(
              onPressed: () => context.push('/accounts/new'),
              child: const Text('添加账户'),
            ),
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
    final inset = dark ? AppColors.bgInset : AppColorsLight.bgInset;
    final hair = dark ? AppColors.hairline : AppColorsLight.hairline;
    final textSec = dark ? AppColors.textSecondary : AppColorsLight.textSecondary;
    final textTer = dark ? AppColors.textTertiary : AppColorsLight.textTertiary;
    final brand = dark ? AppColors.brand : AppColorsLight.brand;
    final warn = dark ? AppColors.warningText : AppColorsLight.warning;

    final snap = o.latestSnapshot;
    final estimated = snap != null &&
        (snap.quality == ValueQuality.estimated ||
            snap.quality == ValueQuality.incomplete);
    final amount = snap == null ? '—' : formatMoney(snap.netWorth);

    final change = o.changeSinceLastSnapshot;
    Widget? deltaPill;
    if (change != null) {
      final down = change.amount.startsWith('-');
      final abs = change.amount.replaceFirst(RegExp(r'^[+-]'), '');
      final label = o.quoteStatusSummary.allFresh ? '今日' : '较上次快照';
      final c = down
          ? (dark ? AppColors.negative : AppColorsLight.negative)
          : (dark ? AppColors.positive : AppColorsLight.positive);
      deltaPill = Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          '${down ? '▼' : '▲'} ¥${formatDecimalThousands(abs)} · $label',
          style: AppType.caption.copyWith(color: c, fontWeight: FontWeight.w600),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: inset,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: hair, width: AppStroke.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 13,
                decoration: BoxDecoration(
                  color: brand,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text('净资产',
                  style: AppType.caption.copyWith(color: textSec, letterSpacing: 0.5)),
              const Spacer(),
              Text('CNY', style: AppType.micro.copyWith(color: textTer)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (estimated)
                Padding(
                  padding: const EdgeInsets.only(right: 6, bottom: 8),
                  child: Text('≈',
                      style: AppType.h1.copyWith(color: textTer)),
                ),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(amount,
                      style: Theme.of(context).textTheme.displayLarge),
                ),
              ),
            ],
          ),
          if (deltaPill != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: deltaPill,
            ),
          if (!o.quoteStatusSummary.allFresh)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Row(
                children: [
                  Icon(Icons.brightness_medium_outlined, size: 14, color: warn),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${o.quoteStatusSummary.staleCount} 项报价过期 · 使用本地缓存',
                      style: AppType.caption.copyWith(color: warn),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => context.push('/snapshots'),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('净值历史'),
                  Icon(Icons.chevron_right, size: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Pending extends StatelessWidget {
  const _Pending({required this.s});
  final PendingSummaryVm s;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    Color col(Color d, Color l) => dark ? d : l;
    final subtle = Theme.of(context).textTheme.bodySmall?.color;

    // 每类待办给一个语义色 + 图标，让「行动中心」一眼可扫、异常态明确。
    final items =
        <({String label, int count, String? route, IconData icon, Color color})>[
      (
        label: 'AI 待确认',
        count: s.aiPendingCount,
        route: '/ai-review',
        icon: Icons.auto_awesome_outlined,
        color: col(AppColors.brandHover, AppColorsLight.brand),
      ),
      (
        label: '账户异常',
        count: s.accountAnomalyCount,
        route: '/anomalies',
        icon: Icons.warning_amber_rounded,
        color: col(AppColors.warningText, AppColorsLight.warning),
      ),
      (
        label: '定投到期',
        count: s.dcaDueCount,
        route: '/investment',
        icon: Icons.event_repeat_outlined,
        color: col(AppColors.infoText, AppColorsLight.info),
      ),
      (
        label: '在途交易',
        count: s.inTransitCount,
        route: null,
        icon: Icons.swap_horiz,
        color: col(AppColors.inTransitText, AppColorsLight.inTransit),
      ),
      (
        label: '报价问题',
        count: s.quoteProblemCount,
        route: null,
        icon: Icons.show_chart,
        color: col(AppColors.warningText, AppColorsLight.warning),
      ),
      (
        label: '同步降级',
        count: s.syncProblemCount,
        route: null,
        icon: Icons.sync_problem,
        color: col(AppColors.errorText, AppColorsLight.error),
      ),
    ].where((e) => e.count > 0).toList();

    return Card(
      margin: const EdgeInsets.only(top: AppSpacing.xl),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.base,
          vertical: AppSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Row(
                children: [
                  Text('待处理',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: AppSpacing.sm),
                  _CountBadge(count: s.total),
                ],
              ),
            ),
            for (final e in items) ...[
              const Divider(height: 1),
              InkWell(
                onTap: e.route == null
                    ? null
                    : () => e.route == '/investment'
                        ? context.go(e.route!)
                        : context.push(e.route!),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                  child: Row(
                    children: [
                      Icon(e.icon, size: 18, color: e.color),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(child: Text(e.label, style: AppType.body)),
                      Text('${e.count}',
                          style: AppType.bodyStrong.copyWith(color: e.color)),
                      const SizedBox(width: AppSpacing.xs),
                      Icon(Icons.chevron_right,
                          size: 18,
                          color: e.route == null ? Colors.transparent : subtle),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// 小圆角计数徽章：品牌金淡底，用于「待处理」总数。
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = dark ? AppColors.brandHover : AppColorsLight.brand;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        '$count',
        style: AppType.micro.copyWith(color: c, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _HoldingRow extends StatelessWidget {
  const _HoldingRow({required this.h});
  final HoldingVm h;

  @override
  Widget build(BuildContext context) {
    final mv = h.marketValue;

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
      dense: true,
      leading: LeadingAvatar.mono(mono),
      title: Text(sym.isEmpty ? '—' : sym, style: AppType.bodyStrong),
      subtitle: Text('持仓 ${h.quantity}', style: AppType.caption),
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
      trailing: amt == null ? null : MoneyText(formatMoney(amt)),
      onTap: () => context.push('/movement/${m.id}'),
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
      trailing: MoneyText.optional(v == null ? null : formatValued(v)),
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
