// Wealth Ledger — 投资页（资产视角：主要持仓 + 定投提醒）。
// 持仓为事实统计（成本/市值/浮盈亏），不做投资建议。定投只提醒，不下单。
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

class InvestmentPage extends ConsumerWidget {
  const InvestmentPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final holdings = ref.watch(holdingsProvider);
    final reminders = ref.watch(dueRemindersProvider);
    final plans =
        ref.watch(dcaPlansProvider).asData?.value ?? const <DcaPlanVm>[];

    return holdings.when(
      loading: () => const ListSkeleton(),
      error: (e, _) => ErrorStateView(
        message: '$e',
        onRetry: () => ref.invalidate(holdingsProvider),
      ),
      data: (hs) {
        final rs = reminders.asData?.value ?? const <DcaReminderVm>[];
        final canPropose = ref.writeCapabilities.canPersistPendingProposal;
        if (hs.isEmpty && rs.isEmpty && plans.isEmpty) {
          return EmptyState(
            illustration: Image.asset(
              'assets/illustrations/investment-empty-state.png',
              width: 176,
              // 品牌插画：金线同心弧 + 圆，与首屏日出成套，喻稳健长期积累。
              semanticLabel: '开始你的投资记录',
            ),
            title: '还没有投资持仓',
            message: '可以先创建定投计划，或添加券商 / 交易所账户与持仓。这里只展示事实统计，非投资建议。',
            action: WriteGate(
              enabled: canPropose,
              child: FilledButton(
                onPressed: () => context.push('/investment/dca/new'),
                child: const Text('新建定投计划'),
              ),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(AppSpacing.base),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: WriteGate(
                enabled: canPropose,
                child: FilledButton.icon(
                  onPressed: () => context.push('/investment/dca/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('新建定投计划'),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            if (hs.isNotEmpty) ...[
              const SectionHeader(title: '主要持仓'),
              for (final h in hs) _HoldingTile(h: h),
            ],
            const SectionHeader(title: '定投提醒'),
            if (rs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Text(
                  '暂无到期定投',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              for (final r in rs) _ReminderTile(r: r),
            if (plans.isNotEmpty) ...[
              const SectionHeader(title: '定投计划'),
              for (final p in plans) _PlanTile(p: p),
            ],
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
    final cost = h.costBasisTotal == null
        ? '成本未记录'
        : '成本 ${formatMoney(h.costBasisTotal!)}';
    final mv = h.marketValue;
    String pnl = '';
    Color? color;
    final p = h.unrealizedPnl;
    if (p != null) {
      final down = p.amount.startsWith('-');
      final abs = p.amount.replaceFirst(RegExp(r'^[+-]'), '');
      final rate = h.unrealizedPnlRate;
      pnl =
          '浮 ${down ? '−' : '+'}¥${formatDecimalThousands(abs)}'
          '${rate == null ? '' : '  ${_pct(rate)}'}';
      color = down
          ? (dark ? AppColors.negative : AppColorsLight.negative)
          : (dark ? AppColors.positive : AppColorsLight.positive);
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: LeadingAvatar.mono(h.symbol),
      title: Text(
        '${h.displayName} · ${h.symbol} · ${h.quantity}',
        style: AppType.bodyStrong,
      ),
      subtitle: Text(
        pnl.isEmpty ? cost : '$cost   $pnl',
        style: AppType.caption.copyWith(color: color),
      ),
      trailing: Text(
        mv == null ? '—' : formatValued(mv),
        style: AppType.moneyRow,
      ),
    );
  }

  String _pct(String rate) {
    // rate 为小数字符串（如 0.0518）→ 估算百分比展示；不参与金额运算。
    final neg = rate.startsWith('-');
    final body = rate.replaceFirst(RegExp(r'^[+-]'), '');
    return '${neg ? '−' : '+'}$body 率';
  }
}

class _ReminderTile extends ConsumerStatefulWidget {
  const _ReminderTile({required this.r});
  final DcaReminderVm r;

  @override
  ConsumerState<_ReminderTile> createState() => _ReminderTileState();
}

class _ReminderTileState extends ConsumerState<_ReminderTile> {
  // 服务端写端点暂无幂等键；请求期间禁用按钮，防止连点生成重复候选。
  bool _busy = false;

  DcaReminderVm get r => widget.r;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.event_repeat_outlined),
      title: Text(r.displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('每期 ${formatMoney(r.plannedAmount)} · 下次 ${r.dueDate}'),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              OutlinedButton(
                // 「记录已执行」只生成待确认候选；无候选持久化能力时禁用。
                onPressed:
                    _busy || !ref.writeCapabilities.canPersistPendingProposal
                    ? null
                    : _record,
                child: const Text('记录已执行'),
              ),
              TextButton(
                onPressed: _busy ? null : _skip,
                child: const Text('跳过本期'),
              ),
              TextButton(
                onPressed: _busy ? null : _snooze,
                child: const Text('明天提醒'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _refresh() {
    ref.invalidate(dueRemindersProvider);
    ref.invalidate(dcaPlansProvider);
    ref.invalidate(overviewProvider);
  }

  Future<void> _run(Future<void> Function() op) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await op();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _record() => _run(() async {
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(dcaRepositoryProvider).markExecutedAsProposal(r.id);
    _refresh();
    ref.invalidate(aiPendingProvider);
    messenger.showSnackBar(
      const SnackBar(content: Text('已生成待确认记录（不下单 / 不转账）；见 AI 待确认')),
    );
  });

  Future<void> _skip() => _run(() async {
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(dcaRepositoryProvider).skipReminder(r.id);
    _refresh();
    messenger.showSnackBar(const SnackBar(content: Text('已跳过本期定投提醒')));
  });

  Future<void> _snooze() => _run(() async {
    final messenger = ScaffoldMessenger.of(context);
    final until = _tomorrowIsoDate();
    await ref.read(dcaRepositoryProvider).snoozeReminder(r.id, until: until);
    _refresh();
    messenger.showSnackBar(SnackBar(content: Text('已暂缓到 $until')));
  });
}

enum _PlanAction { edit, pause, resume, complete }

class _PlanTile extends ConsumerWidget {
  const _PlanTile({required this.p});
  final DcaPlanVm p;

  String get _freq => switch (p.frequency) {
    DcaFrequency.weekly => '每周',
    DcaFrequency.monthly => '每月',
    DcaFrequency.custom => '自定义',
  };

  String get _status => switch (p.status) {
    DcaPlanStatus.active => '进行中',
    DcaPlanStatus.snoozed => '已暂缓',
    DcaPlanStatus.paused => '已暂停',
    DcaPlanStatus.completed => '已完成',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.repeat),
      title: Text(p.displayName),
      subtitle: Text(
        '$_freq ${formatMoney(p.plannedAmount)} · 下次 ${p.nextDueDate} · $_status',
      ),
      trailing: PopupMenuButton<_PlanAction>(
        tooltip: '定投计划操作',
        onSelected: (action) => _handleAction(context, ref, action),
        itemBuilder: (context) => [
          const PopupMenuItem(value: _PlanAction.edit, child: Text('编辑')),
          if (p.status == DcaPlanStatus.active ||
              p.status == DcaPlanStatus.snoozed)
            const PopupMenuItem(value: _PlanAction.pause, child: Text('暂停')),
          if (p.status == DcaPlanStatus.paused)
            const PopupMenuItem(value: _PlanAction.resume, child: Text('恢复')),
          if (p.status != DcaPlanStatus.completed)
            const PopupMenuItem(
              value: _PlanAction.complete,
              child: Text('标记完成'),
            ),
        ],
      ),
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    _PlanAction action,
  ) async {
    switch (action) {
      case _PlanAction.edit:
        await context.push('/investment/dca/${p.id}/edit', extra: p);
      case _PlanAction.pause:
        await _setStatus(context, ref, DcaPlanStatus.paused, '定投计划已暂停');
      case _PlanAction.resume:
        await _setStatus(context, ref, DcaPlanStatus.active, '定投计划已恢复');
      case _PlanAction.complete:
        await _setStatus(context, ref, DcaPlanStatus.completed, '定投计划已标记完成');
    }
  }

  Future<void> _setStatus(
    BuildContext context,
    WidgetRef ref,
    DcaPlanStatus status,
    String message,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(dcaRepositoryProvider)
          .updatePlan(p.id, UpdateDcaPlanPatch(reminderStatus: status));
      ref.invalidate(dcaPlansProvider);
      ref.invalidate(dueRemindersProvider);
      ref.invalidate(overviewProvider);
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

String _tomorrowIsoDate() {
  final tomorrow = DateTime.now().add(const Duration(days: 1));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${tomorrow.year}-${two(tomorrow.month)}-${two(tomorrow.day)}';
}
