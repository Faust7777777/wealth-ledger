// Wealth Ledger — 交易详情（read-only / fixture）。
// 含金额拆分(毛/付/省)字段;已确认记录的修改走"发起更正"(反向+更正,不原地改写)。
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
  final muted = Theme.of(context).textTheme.bodySmall?.color;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
    child: Row(
      children: [
        // 方向指示：中性小圆（in 收/out 付）。方向≠盈亏，故不上语义色。
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Theme.of(context).dividerColor,
            shape: BoxShape.circle,
          ),
          child: Icon(
            isIn ? Icons.south_east : Icons.north_east,
            size: 15,
            color: muted,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            nameById[e.accountId] ?? e.accountId,
            style: AppType.body,
          ),
        ),
        Text(
          '${isIn ? '+' : '−'}${formatMoney(Money(amount: e.amount, currency: e.currency))}',
          style: AppType.moneyRow,
        ),
      ],
    ),
  );
}

/// 已实现盈亏金额：符号 + 语义色（盈利收益色 / 亏损亏损色 / 零中性）。
/// 金额与颜色只来自服务端固化结果，前端不重算、不用当前汇率折算。
Widget _pnlText(BuildContext context, Money pnl) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final sign = decimalSign(pnl.amount);
  final abs = absDecimal(pnl.amount);
  final color = switch (sign) {
    > 0 => dark ? AppColors.positive : AppColorsLight.positive,
    < 0 => dark ? AppColors.negative : AppColorsLight.negative,
    _ => null,
  };
  final prefix = switch (sign) {
    > 0 => '+',
    < 0 => '−',
    _ => '',
  };
  return Text(
    '$prefix${formatMoney(Money(amount: abs, currency: pnl.currency), withCode: true)}',
    style: AppType.moneyRow.copyWith(color: color),
  );
}

Widget _moneyKv(BuildContext context, String k, Money v) => Padding(
  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
  child: Row(
    children: [
      Expanded(child: Text(k, style: AppType.body)),
      Text(formatMoney(v, withCode: true), style: AppType.moneyRow),
    ],
  ),
);

/// 换算依据（服务端固化的成交时汇率）；不展示内部 rate ID。
class _FxBasisTile extends StatelessWidget {
  const _FxBasisTile({required this.title, required this.fx});
  final String title;
  final ExecutionFxBasisVm fx;

  @override
  Widget build(BuildContext context) {
    Widget kv(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
      child: Row(
        children: [
          Expanded(child: Text(k, style: AppType.body)),
          Flexible(child: Text(v, style: AppType.caption)),
        ],
      ),
    );
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(
        left: AppSpacing.sm,
        right: AppSpacing.sm,
        bottom: AppSpacing.xs,
      ),
      title: Text(title, style: AppType.body),
      children: [
        kv('汇率', '1 ${fx.baseCurrency} = ${fx.rate} ${fx.quoteCurrency}'),
        kv('汇率时间', fx.asOf.replaceFirst('T', ' ').split('.').first),
        kv('来源', fx.source),
      ],
    );
  }
}

/// 卖出成交结果（服务端按平均成本法固化；四种盈亏状态按用户语言展示）。
class _SaleResultSection extends StatelessWidget {
  const _SaleResultSection({required this.r});
  final InvestmentSaleResultVm r;

  @override
  Widget build(BuildContext context) {
    final pnl = r.realizedPnl;
    final released = r.costBasisReleased;
    final convertedNet = r.netProceedsInCostBasisCurrency;
    final fx = r.fxBasis;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '成交结果'),
        _moneyKv(context, '毛回款', r.grossProceeds),
        _moneyKv(context, '手续费与税费', r.feeAndTaxTotal),
        _moneyKv(context, '现金净入账', r.netProceeds),
        if (released != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
            child: Row(
              children: [
                Text('本次成本', style: AppType.body),
                const SizedBox(width: AppSpacing.xs),
                // 算法说明收进 tooltip，不常驻正文。
                Tooltip(
                  message: '按平均成本法，从该持仓的总成本中按本次卖出数量比例计算',
                  child: Icon(
                    Icons.info_outline,
                    size: 15,
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
                const Spacer(),
                Text(
                  formatMoney(released, withCode: true),
                  style: AppType.moneyRow,
                ),
              ],
            ),
          ),
        switch (r.realizedPnlStatus) {
          RealizedPnlStatus.calculated ||
          RealizedPnlStatus.calculatedWithFx when pnl != null => Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
            child: Row(
              children: [
                Expanded(child: Text('已实现盈亏', style: AppType.body)),
                _pnlText(context, pnl),
              ],
            ),
          ),
          RealizedPnlStatus.currencyMismatch => Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text('缺少成交时汇率', style: AppType.caption),
          ),
          _ => Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text('盈亏暂不可计算', style: AppType.caption),
          ),
        },
        if (r.realizedPnlStatus == RealizedPnlStatus.calculatedWithFx) ...[
          if (convertedNet != null) _moneyKv(context, '折算净回款', convertedNet),
          if (fx != null) _FxBasisTile(title: '换算依据', fx: fx),
        ],
      ],
    );
  }
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
            final canCorrect =
                m.entries.length == 1 &&
                (m.status == MovementStatus.confirmed ||
                    m.status == MovementStatus.inTransit) &&
                m.type != MovementType.correction;
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.base),
              children: [
                Text(m.title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${_typeLabel(m.type)} · ${m.occurredAt.split('T').first}',
                  style: AppType.caption,
                ),
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
                  if (b.gross != null)
                    _kv(context, '毛额', formatMoney(b.gross!)),
                  if (b.savings != null)
                    _kv(context, '节省', formatMoney(b.savings!)),
                  _kv(context, '实付', formatMoney(b.paid)),
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text('优惠仅作交易字段；节省不计为收入。', style: AppType.caption),
                  ),
                ],
                if (m.entries.isNotEmpty) ...[
                  const SectionHeader(title: '分录'),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? AppColors.surface2
                          : AppColorsLight.surface2,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(
                        color: Theme.of(context).dividerColor,
                        width: AppStroke.hairline,
                      ),
                    ),
                    child: Column(
                      children: [
                        for (final e in m.entries)
                          _entryRow(context, e, nameById),
                      ],
                    ),
                  ),
                ],
                // 卖出成交结果 / 跨币种买入成本换算依据：服务端固化，只读展示；
                // 旧记录缺失字段时不渲染该区块。
                if (m.saleResult != null) _SaleResultSection(r: m.saleResult!),
                if (m.costBasisFx != null)
                  _FxBasisTile(title: '成本换算依据', fx: m.costBasisFx!),
                // 更正=生成候选：不适用的记录（多腿/更正本身）直接隐藏动作；
                // capability 缺失时保留禁用态 + 简短恢复提示。
                if (canCorrect) ...[
                  const SizedBox(height: AppSpacing.lg),
                  OutlinedButton(
                    onPressed: ref.writeCapabilities.canPersistPendingProposal
                        ? () => context.push('/movement/${m.id}/correction')
                        : null,
                    child: const Text('发起更正'),
                  ),
                  if (!ref.writeCapabilities.canPersistPendingProposal)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      child: Text(kReadOnlyHint, style: AppType.caption),
                    ),
                ],
              ],
            );
          },
        ),
      ),
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
