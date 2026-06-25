// Wealth Ledger — ThemeData assembly from P0 tokens (DESIGN_V1.1 §7–§9).
// 深色为默认；浅色对等。颜色经 ColorScheme.fromSeed 生成调性后覆盖关键语义色。
import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_typography.dart';

ThemeData buildDarkTheme() => _build(Brightness.dark);
ThemeData buildLightTheme() => _build(Brightness.light);

ThemeData _build(Brightness brightness) {
  final isDark = brightness == Brightness.dark;

  final scheme = ColorScheme.fromSeed(
    seedColor: isDark ? AppColors.brand : AppColorsLight.brand,
    brightness: brightness,
  ).copyWith(
    primary: isDark ? AppColors.brand : AppColorsLight.brand,
    onPrimary: isDark ? AppColors.onBrand : AppColorsLight.onBrand,
    surface: isDark ? AppColors.surface1 : AppColorsLight.surface1,
    onSurface: isDark ? AppColors.textPrimary : AppColorsLight.textPrimary,
    error: isDark ? AppColors.error : AppColorsLight.error,
  );

  final textPrimary = isDark ? AppColors.textPrimary : AppColorsLight.textPrimary;
  final textSecondary = isDark ? AppColors.textSecondary : AppColorsLight.textSecondary;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: isDark ? AppColors.bgBase : AppColorsLight.bgBase,
    fontFamily: AppType.family,
    fontFamilyFallback: AppType.familyFallback,
    dividerColor: isDark ? AppColors.hairline : AppColorsLight.hairline,
    textTheme: TextTheme(
      displayLarge: AppType.display.copyWith(color: textPrimary),
      headlineMedium: AppType.h1.copyWith(color: textPrimary),
      titleLarge: AppType.h2.copyWith(color: textPrimary),
      titleMedium: AppType.titleM.copyWith(color: textPrimary),
      bodyMedium: AppType.body.copyWith(color: textPrimary),
      bodySmall: AppType.caption.copyWith(color: textSecondary),
      labelSmall: AppType.micro.copyWith(color: textSecondary),
    ),
  );
}
