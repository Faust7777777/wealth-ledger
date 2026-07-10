// Wealth Ledger — FAB「记录」一级选择（手动记账 / 转账 / 余额观察 / AI 导入）。
// 录入均走候选 → 确认；AI 文本/CSV 只生成 proposal，确认前不入账。
// 条目按服务端 capabilities 逐项禁用（手动/转账/校准 → canRecordMovement；
// AI 导入 → canPersistPendingProposal），不按数据源名称猜测。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';

Future<void> showRecordSheet(BuildContext context, LedgerCapabilitiesVm caps) {
  final canRecord = caps.canRecordMovement;
  final canPropose = caps.canPersistPendingProposal;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => SafeArea(
      // 小屏 / 桌面矮窗口下条目较多，允许滚动避免溢出。
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                '记录',
                style: Theme.of(sheetCtx).textTheme.titleMedium,
              ),
              subtitle: Text(
                canRecord || canPropose ? '选择记录方式（候选 → 确认）' : kReadOnlyHint,
              ),
            ),
            _RecordTile(
              sheetCtx: sheetCtx,
              pageCtx: context,
              icon: Icons.edit_outlined,
              label: '手动记账',
              route: '/record/manual',
              enabled: canRecord,
            ),
            _RecordTile(
              sheetCtx: sheetCtx,
              pageCtx: context,
              icon: Icons.swap_horiz,
              label: '转账',
              route: '/record/transfer',
              enabled: canRecord,
            ),
            _RecordTile(
              sheetCtx: sheetCtx,
              pageCtx: context,
              icon: Icons.fact_check_outlined,
              label: '余额观察',
              route: '/record/reconcile',
              enabled: canRecord,
            ),
            _RecordTile(
              sheetCtx: sheetCtx,
              pageCtx: context,
              icon: Icons.auto_awesome_outlined,
              label: 'AI 文本导入',
              route: '/ai-import/text',
              enabled: canPropose,
            ),
            _RecordTile(
              sheetCtx: sheetCtx,
              pageCtx: context,
              icon: Icons.table_chart_outlined,
              label: 'CSV 导入',
              route: '/ai-import/csv',
              enabled: canPropose,
            ),
            _RecordTile(
              sheetCtx: sheetCtx,
              pageCtx: context,
              icon: Icons.image_outlined,
              label: '图片导入',
              route: '/ai-import/image',
              enabled: canPropose,
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    ),
  );
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.sheetCtx,
    required this.pageCtx,
    required this.icon,
    required this.label,
    required this.route,
    required this.enabled,
  });
  final BuildContext sheetCtx;
  final BuildContext pageCtx;
  final IconData icon;
  final String label;
  final String route;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: enabled ? null : const Text('当前数据源不支持'),
      enabled: enabled,
      onTap: enabled
          ? () {
              Navigator.of(sheetCtx).pop();
              pageCtx.push(route);
            }
          : null,
    );
  }
}
