// Wealth Ledger — 列表行首方形徽标：品牌金淡底，内含类型图标或短字母(monogram)。
// 统一 概览/账户/投资 各行的行首视觉，属方向无关 Phase-2 地基之一。
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

class LeadingAvatar extends StatelessWidget {
  /// 图标徽标：账户类型 / 操作入口。
  const LeadingAvatar.icon(this.icon, {super.key, this.size = 38}) : mono = null;

  /// 字母徽标：券商代码等短字符（取前 2 字，大写）。
  const LeadingAvatar.mono(this.mono, {super.key, this.size = 38}) : icon = null;

  final IconData? icon;
  final String? mono;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final brand = dark ? AppColors.brandHover : AppColorsLight.brand;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: brand.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: icon != null
          ? Icon(icon, size: size * 0.5, color: brand)
          : Text(
              mono!,
              style: AppType.caption
                  .copyWith(color: brand, fontWeight: FontWeight.w700),
            ),
    );
  }
}
