// Wealth Ledger — ThemeData assembly from P0 tokens (DESIGN_V1.1 §7–§9).
// 深色为默认；浅色对等。颜色经 ColorScheme.fromSeed 生成调性后覆盖关键语义色。
// 组件层：给 M3 组件接上一套「surface + hairline、克制圆角、无阴影」的子主题，
// 让页面不改代码就摆脱 stock Material 外观。配色仍全部来自 token（方向无关，可逆）。
import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_dimens.dart';
import 'app_typography.dart';

ThemeData buildDarkTheme() => _build(Brightness.dark);
ThemeData buildLightTheme() => _build(Brightness.light);

ThemeData _build(Brightness brightness) {
  final isDark = brightness == Brightness.dark;

  T pick<T>(T dark, T light) => isDark ? dark : light;

  final bg = pick(AppColors.bgBase, AppColorsLight.bgBase);
  final surface1 = pick(AppColors.surface1, AppColorsLight.surface1);
  final surface2 = pick(AppColors.surface2, AppColorsLight.surface2);
  final surface3 = pick(AppColors.surface3, AppColorsLight.surface3);
  final hairline = pick(AppColors.hairline, AppColorsLight.hairline);
  final hairlineStrong = pick(AppColors.hairlineStrong, AppColorsLight.hairlineStrong);
  final textPrimary = pick(AppColors.textPrimary, AppColorsLight.textPrimary);
  final textSecondary = pick(AppColors.textSecondary, AppColorsLight.textSecondary);
  final textTertiary = pick(AppColors.textTertiary, AppColorsLight.textTertiary);
  final brand = pick(AppColors.brand, AppColorsLight.brand);
  final onBrand = pick(AppColors.onBrand, AppColorsLight.onBrand);
  final errorC = pick(AppColors.error, AppColorsLight.error);

  final scheme = ColorScheme.fromSeed(
    seedColor: brand,
    brightness: brightness,
  ).copyWith(
    primary: brand,
    onPrimary: onBrand,
    surface: surface1,
    onSurface: textPrimary,
    onSurfaceVariant: textSecondary,
    outline: hairlineStrong,
    outlineVariant: hairline,
    error: errorC,
  );

  final textTheme = TextTheme(
    displayLarge: AppType.display.copyWith(color: textPrimary),
    headlineMedium: AppType.h1.copyWith(color: textPrimary),
    titleLarge: AppType.h2.copyWith(color: textPrimary),
    titleMedium: AppType.titleM.copyWith(color: textPrimary),
    bodyMedium: AppType.body.copyWith(color: textPrimary),
    bodySmall: AppType.caption.copyWith(color: textSecondary),
    labelSmall: AppType.micro.copyWith(color: textSecondary),
  );

  RoundedRectangleBorder r(double radius, {Color? side, double w = AppStroke.hairline}) =>
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: side == null ? BorderSide.none : BorderSide(color: side, width: w),
      );

  final buttonShape = r(AppRadius.md);
  const buttonPad = EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md);

  OutlineInputBorder inputBorder(Color color, double w) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: color, width: w),
      );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    fontFamily: AppType.family,
    fontFamilyFallback: AppType.familyFallback,
    textTheme: textTheme,
    dividerColor: hairline,
    hoverColor: brand.withValues(alpha: 0.05),
    splashColor: brand.withValues(alpha: 0.06),
    highlightColor: brand.withValues(alpha: 0.04),
    iconTheme: IconThemeData(color: textSecondary, size: 22),

    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: AppType.h2.copyWith(color: textPrimary),
      iconTheme: IconThemeData(color: textSecondary, size: 22),
    ),

    cardTheme: CardThemeData(
      color: surface1,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: r(AppRadius.lg, side: hairline),
    ),

    dividerTheme: DividerThemeData(
      color: hairline,
      thickness: AppStroke.hairline,
      space: AppStroke.hairline,
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: brand,
        foregroundColor: onBrand,
        elevation: 0,
        padding: buttonPad,
        minimumSize: const Size(0, 44),
        shape: buttonShape,
        textStyle: AppType.bodyStrong,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: textPrimary,
        padding: buttonPad,
        minimumSize: const Size(0, 44),
        side: BorderSide(color: hairlineStrong, width: AppStroke.hairline),
        shape: buttonShape,
        textStyle: AppType.bodyStrong,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: brand,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        shape: buttonShape,
        textStyle: AppType.bodyStrong,
      ),
    ),

    listTileTheme: ListTileThemeData(
      iconColor: textSecondary,
      textColor: textPrimary,
      minVerticalPadding: AppSpacing.sm,
      horizontalTitleGap: AppSpacing.md,
      shape: r(AppRadius.md),
      subtitleTextStyle: AppType.caption.copyWith(color: textSecondary),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: surface2,
      side: BorderSide(color: hairline, width: AppStroke.hairline),
      shape: const StadiumBorder(),
      labelStyle: AppType.micro.copyWith(color: textSecondary),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: pick(AppColors.bgInset, AppColorsLight.surface1),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.md,
      ),
      border: inputBorder(hairline, AppStroke.hairline),
      enabledBorder: inputBorder(hairline, AppStroke.hairline),
      focusedBorder: inputBorder(brand, AppStroke.focus),
      errorBorder: inputBorder(errorC, AppStroke.hairline),
      focusedErrorBorder: inputBorder(errorC, AppStroke.focus),
      labelStyle: AppType.body.copyWith(color: textSecondary),
      floatingLabelStyle: AppType.caption.copyWith(color: brand),
      hintStyle: AppType.body.copyWith(color: textTertiary),
      helperStyle: AppType.caption.copyWith(color: textTertiary),
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: surface1,
        foregroundColor: textSecondary,
        selectedBackgroundColor: brand.withValues(alpha: isDark ? 0.18 : 0.14),
        selectedForegroundColor: textPrimary,
        side: BorderSide(color: hairline, width: AppStroke.hairline),
        shape: r(AppRadius.md),
        textStyle: AppType.bodyStrong,
      ),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: surface3,
      contentTextStyle: AppType.body.copyWith(color: textPrimary),
      actionTextColor: brand,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: r(AppRadius.md, side: hairline),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: surface2,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: r(AppRadius.lg, side: hairline),
      titleTextStyle: AppType.h2.copyWith(color: textPrimary),
      contentTextStyle: AppType.body.copyWith(color: textPrimary),
    ),

    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface1,
      surfaceTintColor: Colors.transparent,
      indicatorColor: brand.withValues(alpha: isDark ? 0.18 : 0.14),
      elevation: 0,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => AppType.micro.copyWith(
          color: s.contains(WidgetState.selected) ? textPrimary : textTertiary,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          size: 22,
          color: s.contains(WidgetState.selected) ? brand : textSecondary,
        ),
      ),
    ),

    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: bg,
      indicatorColor: brand.withValues(alpha: isDark ? 0.18 : 0.14),
      selectedIconTheme: IconThemeData(color: brand, size: 24),
      unselectedIconTheme: IconThemeData(color: textSecondary, size: 24),
      selectedLabelTextStyle: AppType.micro.copyWith(color: textPrimary),
      unselectedLabelTextStyle: AppType.micro.copyWith(color: textTertiary),
    ),
  );
}
