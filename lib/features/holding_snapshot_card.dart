// Wealth Ledger — 持仓快照审核卡：同一 atomic group 里的多条持仓调整合成一张卡。
// 确认前不改变任何持仓；只提供整组采用/忽略，没有逐项确认。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

/// 服务端给持仓快照候选打的标签。
const String kHoldingSnapshotTag = 'holding_snapshot';

/// 该审核组是否是多资产持仓快照。
bool isHoldingSnapshotGroup(AiAtomicGroupVm group) =>
    group.proposedMovements.any((m) => m.tags.contains(kHoldingSnapshotTag));

/// 组内按标的排好的持仓变化。数量一律按十进制字符串比较与展示。
List<MovementVm> holdingSnapshotMovements(AiAtomicGroupVm group) => [
  for (final m in group.proposedMovements)
    if (m.tags.contains(kHoldingSnapshotTag) && m.holdingAdjustment != null) m,
];

/// 组内涉及的账户 ID：优先 holdingAdjustment.accountId，退回 entry 的 accountId。
/// 用于审核动作后精确失效该账户的详情与持仓，不必退出重进。
Set<Id> holdingGroupAccountIds(AiAtomicGroupVm group) {
  final ids = <Id>{};
  for (final m in group.proposedMovements) {
    final adjustment = m.holdingAdjustment;
    if (adjustment != null && adjustment.accountId.isNotEmpty) {
      ids.add(adjustment.accountId);
      continue;
    }
    for (final e in m.entries) {
      if (e.accountId.isNotEmpty) ids.add(e.accountId);
    }
  }
  return ids;
}

/// 快照卡：默认只报变化项数，展开后逐项显示 previous → target。
class HoldingSnapshotCard extends ConsumerStatefulWidget {
  const HoldingSnapshotCard({super.key, required this.group});
  final AiAtomicGroupVm group;

  @override
  ConsumerState<HoldingSnapshotCard> createState() =>
      _HoldingSnapshotCardState();
}

class _HoldingSnapshotCardState extends ConsumerState<HoldingSnapshotCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final changes = holdingSnapshotMovements(widget.group);
    final instruments =
        ref.watch(instrumentsProvider).asData?.value ?? const <InstrumentVm>[];
    final byId = {for (final i in instruments) i.id: i};
    final skipped = widget.group.skippedPositions;

    String label(String instrumentId) {
      final inst = byId[instrumentId];
      if (inst == null) return instrumentId;
      final symbol = inst.symbol;
      return symbol == null || symbol.isEmpty
          ? inst.displayName
          : '${inst.displayName} · $symbol';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${changes.length} 项数量变化',
                style: AppType.body,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              key: kHoldingSnapshotExpandKey,
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? '收起' : '展开'),
            ),
          ],
        ),
        if (skipped.isNotEmpty)
          Text('${skipped.length} 项数量未变化', style: AppType.caption),
        if (_expanded)
          for (final m in changes)
            _SnapshotRow(
              key: ValueKey('holding_snapshot_row_${m.id}'),
              label: label(m.holdingAdjustment!.instrumentId),
              adjustment: m.holdingAdjustment!,
            ),
      ],
    );
  }
}

/// 展开入口的稳定 Key（回归测试用）。
const kHoldingSnapshotExpandKey = ValueKey('holding_snapshot_expand');

class _SnapshotRow extends StatelessWidget {
  const _SnapshotRow({
    super.key,
    required this.label,
    required this.adjustment,
  });
  final String label;
  final HoldingAdjustmentVm adjustment;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: AppType.caption,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            '${formatDecimalThousands(adjustment.previousQuantity)} → '
            '${formatDecimalThousands(adjustment.targetQuantity)}',
            style: AppType.moneyRow,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    ),
  );
}
