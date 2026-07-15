// Wealth Ledger — 负债页。账本内欠款为负，但界面按语义展示：
// 欠款显示绝对值+「当前欠款」，0=「已还清」，正数=「溢缴款」，不出现负号。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import 'account_visuals.dart';

class LiabilitiesPage extends ConsumerWidget {
  const LiabilitiesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(liabilitiesProvider);
    return async.when(
      loading: () => const ListSkeleton(),
      error: (e, _) => ErrorStateView(
        message: '$e',
        onRetry: () => ref.invalidate(liabilitiesProvider),
      ),
      data: (items) {
        if (items.isEmpty) {
          return EmptyState(
            icon: Icons.account_balance_outlined,
            title: '暂无负债账户',
            action: WriteGate(
              enabled: ref.writeCapabilities.canCreateAccount,
              child: FilledButton(
                // 从负债页进入时默认选中「信用卡」，不默认银行。
                onPressed: () => context.push('/accounts/new?type=creditCard'),
                child: const Text('添加信用卡或贷款'),
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(AppSpacing.base),
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final a = items[i];
            return Reveal(
              delay: Duration(milliseconds: (i * 40).clamp(0, 240)),
              child: PressableScale(
                onTap: () => context.push('/account/${a.id}'),
                child: ListTile(
                  leading: LeadingAvatar.icon(accountTypeIcon(a.accountType)),
                  title: Text(a.displayName),
                  subtitle: Text(
                    a.note == null
                        ? accountTypeLabel(a.accountType)
                        : '${accountTypeLabel(a.accountType)} · ${a.note}',
                  ),
                  trailing: AccountValueDisplay(account: a),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
