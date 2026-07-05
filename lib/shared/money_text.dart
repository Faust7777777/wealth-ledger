// Wealth Ledger — 金额显示原语：统一 tabular 对齐 + 语义色调 + 空态占位。
// 纯表现层，不做任何金额运算；调用方传入已格式化的字符串与语义色调。
// 方向无关 Phase-2 地基之一（后续配 StatusPill）。
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

/// 控制台里金额只应走这几种语义色调。
enum MoneyTone { normal, muted, positive, negative, warning, brand }

Color _toneColor(MoneyTone tone, bool dark) {
  switch (tone) {
    case MoneyTone.normal:
      return dark ? AppColors.textPrimary : AppColorsLight.textPrimary;
    case MoneyTone.muted:
      return dark ? AppColors.textTertiary : AppColorsLight.textTertiary;
    case MoneyTone.positive:
      return dark ? AppColors.positive : AppColorsLight.positive;
    case MoneyTone.negative:
      return dark ? AppColors.negative : AppColorsLight.negative;
    case MoneyTone.warning:
      return dark ? AppColors.warningText : AppColorsLight.warning;
    case MoneyTone.brand:
      return dark ? AppColors.brandHover : AppColorsLight.brand;
  }
}

/// 单行金额文本。默认等宽数字（[AppType.moneyRow]）以成列对齐。
///
/// - [tone] 决定颜色语义；`—`/空串一律按 [MoneyTone.muted] 显示。
/// - [prefix] 是弱化的前缀标记（如 `≈ ` 估算 / `浮 ` 浮盈亏），比正文更淡。
/// - [emphasis] 加重字重到 w600（用于主市值）。
class MoneyText extends StatelessWidget {
  const MoneyText(
    this.text, {
    super.key,
    this.tone = MoneyTone.normal,
    this.style,
    this.prefix,
    this.emphasis = false,
  });

  /// 空值便捷构造：`null` → 显示占位符（默认 `—`，muted）。
  const MoneyText.optional(
    String? value, {
    super.key,
    this.tone = MoneyTone.normal,
    this.style,
    this.prefix,
    this.emphasis = false,
    String placeholder = '—',
  }) : text = value ?? placeholder;

  final String text;
  final MoneyTone tone;
  final TextStyle? style;
  final String? prefix;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final isPlaceholder = text.isEmpty || text == '—';
    final color = _toneColor(isPlaceholder ? MoneyTone.muted : tone, dark);
    final base = style ?? AppType.moneyRow;
    final resolved = base.copyWith(
      color: color,
      fontWeight: emphasis ? FontWeight.w600 : base.fontWeight,
    );
    if (prefix == null) return Text(text, style: resolved);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: prefix,
            style: resolved.copyWith(color: color.withValues(alpha: 0.65)),
          ),
          TextSpan(text: text, style: resolved),
        ],
      ),
    );
  }
}
