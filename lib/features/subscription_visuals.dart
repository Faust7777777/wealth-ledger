// Wealth Ledger — 订阅展示助手：状态色/文案、周期/时长文案、日期工具。
// 颜色只取现有语义 token（app_colors），不新增第二套色板。
import 'package:flutter/material.dart';

import '../data/view_models.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';

String subscriptionStatusLabel(SubscriptionStatus s) => switch (s) {
  SubscriptionStatus.trial => '试用',
  SubscriptionStatus.active => '生效中',
  SubscriptionStatus.paused => '已暂停',
  SubscriptionStatus.cancelled => '已取消',
  SubscriptionStatus.expired => '已到期',
};

/// 状态色：均取语义 token。到期/取消用中性 textTertiary（不制造恐慌，不用 error 红）。
Color subscriptionStatusColor(SubscriptionStatus s, {required bool dark}) {
  Color pick(Color d, Color l) => dark ? d : l;
  return switch (s) {
    SubscriptionStatus.trial => pick(AppColors.info, AppColorsLight.info),
    SubscriptionStatus.active => pick(
      AppColors.positive,
      AppColorsLight.positive,
    ),
    SubscriptionStatus.paused => pick(
      AppColors.warning,
      AppColorsLight.warning,
    ),
    SubscriptionStatus.cancelled => pick(
      AppColors.textTertiary,
      AppColorsLight.textTertiary,
    ),
    SubscriptionStatus.expired => pick(
      AppColors.textTertiary,
      AppColorsLight.textTertiary,
    ),
  };
}

String billingCycleLabel(SubscriptionBillingCycleVm c) {
  final unit = switch (c.unit) {
    BillingUnit.day => '日',
    BillingUnit.week => '周',
    BillingUnit.month => '月',
    BillingUnit.year => '年',
  };
  return c.interval == 1 ? '每$unit' : '每 ${c.interval} $unit';
}

String durationLabel(SubscriptionDurationVm d) {
  final unit = switch (d.unit) {
    SubscriptionDurationUnit.day => '天',
    SubscriptionDurationUnit.month => '个月',
    SubscriptionDurationUnit.year => '年',
  };
  return '${d.count} $unit';
}

/// 本地日历日期字符串（YYYY-MM-DD）。绝不经 UTC 转换，避免跨时区改变日历日。
String isoDateOf(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
}

String todayIsoDate() => isoDateOf(DateTime.now());

/// 逾期判断：按零填充 ISO 日期做字典序比较即可（无需转 DateTime）。
bool isOverdueChargeDate(String? nextChargeDate, {String? today}) {
  if (nextChargeDate == null) return false;
  return nextChargeDate.compareTo(today ?? todayIsoDate()) < 0;
}

/// 订阅状态药丸：统一 trial/active/paused/cancelled/expired 短状态。
class SubscriptionStatusPill extends StatelessWidget {
  const SubscriptionStatusPill(this.status, {super.key});
  final SubscriptionStatus status;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = subscriptionStatusColor(status, dark: dark);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.16 : 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        subscriptionStatusLabel(status),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
