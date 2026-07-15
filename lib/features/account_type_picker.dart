// Wealth Ledger — 账户类型分组选择器。
// 弹窗形式：内容宽度受限、列表内部滚动，桌面上不再出现占据大半屏的巨型下拉层。
// 只显示用户可见名称+示例，不显示 wire enum / balanceMode / 实现解释。
import 'package:flutter/material.dart';

import '../data/view_models.dart';
import '../theme/app_dimens.dart';
import 'account_visuals.dart';

Future<AccountType?> showAccountTypePicker(
  BuildContext context, {
  AccountType? selected,
}) => showDialog<AccountType>(
  context: context,
  builder: (_) => AccountTypePickerDialog(selected: selected),
);

class AccountTypePickerDialog extends StatelessWidget {
  const AccountTypePickerDialog({super.key, this.selected});
  final AccountType? selected;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // 列表高度不超过约半屏（240–420），窗口再矮也可滚动，不占据整屏。
    final maxListHeight = (MediaQuery.sizeOf(context).height * 0.5).clamp(
      240.0,
      420.0,
    );
    return AlertDialog(
      title: const Text('账户类型'),
      contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      content: SizedBox(
        width: 400,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxListHeight),
          // 11 项为固定小清单：用非惰性 Column 滚动，选项全量构建。
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final g in kAccountTypeGroups) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.sm,
                      AppSpacing.lg,
                      AppSpacing.xxs,
                    ),
                    child: Text(
                      g.label,
                      style: t.textTheme.labelSmall?.copyWith(
                        color: t.colorScheme.outline,
                      ),
                    ),
                  ),
                  for (final type in g.types)
                    ListTile(
                      leading: Icon(accountTypeIcon(type)),
                      title: Text(accountTypeLabel(type)),
                      subtitle: Text(accountTypeExample(type)),
                      trailing: type == selected
                          ? const Icon(Icons.check)
                          : null,
                      selected: type == selected,
                      onTap: () => Navigator.pop(context, type),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
