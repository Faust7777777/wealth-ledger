// Wealth Ledger — FAB "记录" 一级选择（手动记账 / 转账 / 余额观察 / AI 导入）。
// 第一阶段为入口壳：实际录入走"候选→确认"，后续批次接入。
import 'package:flutter/material.dart';
import '../theme/app_dimens.dart';

Future<void> showRecordSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text('记录', style: Theme.of(sheetContext).textTheme.titleMedium),
            subtitle: const Text('选择记录方式（候选 → 确认；后续批次接入）'),
          ),
          _RecordTile(icon: Icons.edit_outlined, label: '手动记账'),
          _RecordTile(icon: Icons.swap_horiz, label: '转账'),
          _RecordTile(icon: Icons.fact_check_outlined, label: '余额观察'),
          _RecordTile(icon: Icons.auto_awesome_outlined, label: 'AI 导入'),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    ),
  );
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      onTap: () {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$label：待后续批次接入（生成候选记录，确认后入账）')),
        );
      },
    );
  }
}
