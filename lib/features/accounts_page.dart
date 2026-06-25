// Wealth Ledger — 账户页（多币种容器；空态 / DEMO）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../data/providers.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'account_visuals.dart';

class AccountsPage extends ConsumerWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(accountsProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          ErrorStateView(message: '$e', onRetry: () => ref.invalidate(accountsProvider)),
      data: (accounts) {
        if (accounts.isEmpty) {
          return const EmptyState(
            icon: Icons.account_balance_wallet_outlined,
            title: '还没有账户',
            message: '从右下「记录」或账户管理添加你的第一个账户。',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(AppSpacing.base),
          itemCount: accounts.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final a = accounts[i];
            final v = a.value;
            return ListTile(
              leading: Icon(accountTypeIcon(a.accountType)),
              title: Text(a.displayName),
              subtitle: Text(
                a.note == null
                    ? accountTypeLabel(a.accountType)
                    : '${accountTypeLabel(a.accountType)} · ${a.note}',
              ),
              trailing: Text(
                v == null ? '—' : formatValued(v),
                style: AppType.moneyRow,
              ),
            );
          },
        );
      },
    );
  }
}
