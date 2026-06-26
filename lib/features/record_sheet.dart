// Wealth Ledger — FAB「记录」一级选择（手动记账 / 转账 / 余额观察 / AI 导入）。
// 手动/转账/余额观察 录入屏后续批次；AI 导入已接入文本输入屏（候选 → 确认）。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_dimens.dart';

Future<void> showRecordSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text('记录', style: Theme.of(sheetCtx).textTheme.titleMedium),
            subtitle: const Text('选择记录方式（候选 → 确认）'),
          ),
          _RecordTile(sheetCtx: sheetCtx, pageCtx: context, icon: Icons.edit_outlined, label: '手动记账', route: '/record/manual'),
          _RecordTile(sheetCtx: sheetCtx, pageCtx: context, icon: Icons.swap_horiz, label: '转账', route: '/record/transfer'),
          _RecordTile(sheetCtx: sheetCtx, pageCtx: context, icon: Icons.fact_check_outlined, label: '余额观察'),
          _RecordTile(
            sheetCtx: sheetCtx,
            pageCtx: context,
            icon: Icons.auto_awesome_outlined,
            label: 'AI 导入',
            route: '/ai-import/text',
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
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
    this.route,
  });
  final BuildContext sheetCtx;
  final BuildContext pageCtx;
  final IconData icon;
  final String label;
  final String? route;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      onTap: () {
        Navigator.of(sheetCtx).pop();
        final r = route;
        if (r != null) {
          pageCtx.push(r);
        } else {
          ScaffoldMessenger.of(pageCtx).showSnackBar(
            SnackBar(content: Text('$label：后续批次接入（生成候选记录，确认后入账）')),
          );
        }
      },
    );
  }
}
