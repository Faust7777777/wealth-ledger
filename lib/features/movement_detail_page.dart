// Wealth Ledger — 交易详情（read-only / fixture）。
// 含金额拆分(毛/付/省)字段;已确认记录的修改走"发起更正"(反向+更正,不原地改写)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

String _typeLabel(MovementType t) => switch (t) {
      MovementType.income => '收入',
      MovementType.expense => '支出',
      MovementType.transfer => '转账',
      MovementType.buy => '买入',
      MovementType.sell => '卖出',
      MovementType.dividend => '分红',
      MovementType.interest => '利息',
      MovementType.fee => '费用',
      MovementType.adjustment => '调整',
      MovementType.loanDisbursement => '放款',
      MovementType.loanRepayment => '还款',
      MovementType.correction => '更正',
    };

Widget _entryRow(
  BuildContext context,
  MovementEntryVm e,
  Map<String, String> nameById,
) {
  final isIn = e.direction == 'in';
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
    child: Row(
      children: [
        Icon(isIn ? Icons.arrow_downward : Icons.arrow_upward, size: 16),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(nameById[e.accountId] ?? e.accountId, style: AppType.body),
        ),
        Text(
          '${isIn ? '+' : '−'}${formatMoney(Money(amount: e.amount, currency: e.currency))}',
          style: AppType.moneyRow,
        ),
      ],
    ),
  );
}

class MovementDetailPage extends ConsumerWidget {
  const MovementDetailPage({super.key, required this.movementId});
  final String movementId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(movementByIdProvider(movementId));
    final accounts =
        ref.watch(accountsProvider).asData?.value ?? const <AccountVm>[];
    final nameById = {for (final a in accounts) a.id: a.displayName};
    return Scaffold(
      appBar: AppBar(title: const Text('交易详情')),
      body: ContentMaxWidth(
          child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorStateView(
          message: '$e',
          onRetry: () => ref.invalidate(movementByIdProvider(movementId)),
        ),
        data: (m) {
          if (m == null) {
            return const EmptyState(icon: Icons.help_outline, title: '记录不存在');
          }
          final b = m.amountBreakdown;
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.base),
            children: [
              Text(m.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: AppSpacing.xs),
              Text('${_typeLabel(m.type)} · ${m.occurredAt.split('T').first}',
                  style: AppType.caption),
              if (m.inTransit)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text('在途 · 非支出', style: AppType.caption),
                ),
              const SizedBox(height: AppSpacing.base),
              if (m.displayAmount != null)
                _kv(context, '金额', formatMoney(m.displayAmount!)),
              if (b != null) ...[
                const Divider(),
                if (b.gross != null) _kv(context, '毛额', formatMoney(b.gross!)),
                if (b.savings != null) _kv(context, '节省', formatMoney(b.savings!)),
                _kv(context, '实付', formatMoney(b.paid)),
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text('优惠仅作交易字段；节省不计为收入。', style: AppType.caption),
                ),
              ],
              if (m.entries.isNotEmpty) ...[
                const Divider(),
                const SectionHeader(title: '分录'),
                for (final e in m.entries) _entryRow(context, e, nameById),
              ],
              const SizedBox(height: AppSpacing.lg),
              OutlinedButton(
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('发起更正：后续批次（已确认记录走反向 + 更正，不原地改写）'),
                  ),
                ),
                child: const Text('发起更正'),
              ),
            ],
          );
        },
      )),
    );
  }

  Widget _kv(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
        child: Row(
          children: [
            Expanded(child: Text(k, style: AppType.body)),
            Text(v, style: AppType.moneyRow),
          ],
        ),
      );
}
