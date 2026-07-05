// Wealth Ledger — 状态徽章原语：小圆角 pill，语义色淡底 + 可选前导图标。
// 统一「操作类型 / 在途 / 同步 / 过期 / 行情状态」等短状态标记，配 MoneyText 使用。
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

/// 控制台里状态标记只应走这几种语义。
enum StatusTone { neutral, brand, info, positive, negative, warning, danger, inTransit }

Color _toneColor(StatusTone tone, bool dark) {
  switch (tone) {
    case StatusTone.neutral:
      return dark ? AppColors.textSecondary : AppColorsLight.textSecondary;
    case StatusTone.brand:
      return dark ? AppColors.brandHover : AppColorsLight.brand;
    case StatusTone.info:
      return dark ? AppColors.infoText : AppColorsLight.info;
    case StatusTone.positive:
      return dark ? AppColors.positiveText : AppColorsLight.positive;
    case StatusTone.negative:
      return dark ? AppColors.negativeText : AppColorsLight.negative;
    case StatusTone.warning:
      return dark ? AppColors.warningText : AppColorsLight.warning;
    case StatusTone.danger:
      return dark ? AppColors.errorText : AppColorsLight.error;
    case StatusTone.inTransit:
      return dark ? AppColors.inTransitText : AppColorsLight.inTransit;
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, this.tone = StatusTone.neutral, this.icon});

  final String label;
  final StatusTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = _toneColor(tone, dark);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: c),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: AppType.micro.copyWith(color: c, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
