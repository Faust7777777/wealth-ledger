// Wealth Ledger — 账户异常统一出口（read-only；DESIGN_V2.1 §AccountAnomalyList）。
// 异常绝不隐藏；severity 决定颜色，但仍可展开查看。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';

Color _sevColor(BuildContext c, AnomalySeverity s) {
  final dark = Theme.of(c).brightness == Brightness.dark;
  return switch (s) {
    AnomalySeverity.critical => dark ? AppColors.error : AppColorsLight.error,
    AnomalySeverity.warning => dark ? AppColors.warning : AppColorsLight.warning,
    AnomalySeverity.info => dark ? AppColors.info : AppColorsLight.info,
  };
}

IconData _sevIcon(AnomalySeverity s) => switch (s) {
      AnomalySeverity.critical => Icons.error_outline,
      AnomalySeverity.warning => Icons.warning_amber_outlined,
      AnomalySeverity.info => Icons.info_outline,
    };

class AnomaliesPage extends ConsumerWidget {
  const AnomaliesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(anomaliesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('账户异常')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorStateView(
          message: '$e',
          onRetry: () => ref.invalidate(anomaliesProvider),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.check_circle_outline,
              title: '一切就绪',
              message: '没有需要处理的账户异常。',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.base),
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final a = items[i];
              return ListTile(
                leading: Icon(_sevIcon(a.severity), color: _sevColor(context, a.severity)),
                title: Text(a.accountName),
                subtitle: Text(a.detail),
              );
            },
          );
        },
      ),
    );
  }
}
