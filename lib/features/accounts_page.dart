// Wealth Ledger — 账户页（多币种容器；空态 / DEMO）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
          return EmptyState(
            icon: Icons.account_balance_wallet_outlined,
            title: '还没有账户',
            message: '添加你的第一个账户，开始记录净资产。',
            action: FilledButton(
              onPressed: () => context.push('/accounts/new'),
              child: const Text('添加账户'),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(AppSpacing.base),
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('添加账户'),
              onTap: () => context.push('/accounts/new'),
            ),
            const Divider(height: 1),
            for (final a in accounts) ...[
              ListTile(
                leading: Icon(accountTypeIcon(a.accountType)),
                title: Text(a.displayName),
                subtitle: Text(
                  a.note == null
                      ? accountTypeLabel(a.accountType)
                      : '${accountTypeLabel(a.accountType)} · ${a.note}',
                ),
                trailing: Text(
                  a.value == null ? '—' : formatValued(a.value!),
                  style: AppType.moneyRow,
                ),
                onTap: () => context.push('/account/${a.id}'),
              ),
              const Divider(height: 1),
            ],
          ],
        );
      },
    );
  }
}
