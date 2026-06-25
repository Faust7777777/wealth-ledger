// Wealth Ledger — 负债页（负债账户；为负=正常负债，不算异常）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../data/providers.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'account_visuals.dart';

class LiabilitiesPage extends ConsumerWidget {
  const LiabilitiesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(liabilitiesProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          ErrorStateView(message: '$e', onRetry: () => ref.invalidate(liabilitiesProvider)),
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(
            icon: Icons.account_balance_outlined,
            title: '没有负债',
            message: '信用卡、贷款等负债会显示在这里；负债余额为负是正常的。',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(AppSpacing.base),
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final a = items[i];
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
