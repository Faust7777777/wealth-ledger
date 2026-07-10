// Wealth Ledger — ThemeData assembly from P0 tokens (DESIGN_V1.1 §7–§9).
// 深色为默认；浅色对等。颜色经 ColorScheme.fromSeed 生成调性后覆盖关键语义色。
import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_typography.dart';

/// 全局页面转场：淡入 + 极轻上滑，替换各平台默认（Windows 默认偏生硬）。
/// 一处定义、所有 push 路由生效；契合「calm」基调。
class _CalmPageTransitionsBuilder extends PageTransitionsBuilder {
  const _CalmPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.02),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

const _calmPageTransitions = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: _CalmPageTransitionsBuilder(),
    TargetPlatform.iOS: _CalmPageTransitionsBuilder(),
    TargetPlatform.linux: _CalmPageTransitionsBuilder(),
    TargetPlatform.macOS: _CalmPageTransitionsBuilder(),
    TargetPlatform.windows: _CalmPageTransitionsBuilder(),
    TargetPlatform.fuchsia: _CalmPageTransitionsBuilder(),
  },
);

ThemeData buildDarkTheme() => _build(Brightness.dark);
ThemeData buildLightTheme() => _build(Brightness.light);

ThemeData _build(Brightness brightness) {
  final isDark = brightness == Brightness.dark;

  final scheme =
      ColorScheme.fromSeed(
        seedColor: isDark ? AppColors.brand : AppColorsLight.brand,
        brightness: brightness,
      ).copyWith(
        primary: isDark ? AppColors.brand : AppColorsLight.brand,
        onPrimary: isDark ? AppColors.onBrand : AppColorsLight.onBrand,
        surface: isDark ? AppColors.surface1 : AppColorsLight.surface1,
        onSurface: isDark ? AppColors.textPrimary : AppColorsLight.textPrimary,
        error: isDark ? AppColors.error : AppColorsLight.error,
      );

  final textPrimary = isDark
      ? AppColors.textPrimary
      : AppColorsLight.textPrimary;
  final textSecondary = isDark
      ? AppColors.textSecondary
      : AppColorsLight.textSecondary;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: isDark ? AppColors.bgBase : AppColorsLight.bgBase,
    fontFamily: AppType.family,
    fontFamilyFallback: AppType.familyFallback,
    dividerColor: isDark ? AppColors.hairline : AppColorsLight.hairline,
    pageTransitionsTheme: _calmPageTransitions,
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
