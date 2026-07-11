// Wealth Ledger — ThemeData assembly from P0 tokens (DESIGN_V1.1 §7–§9).
// 深色为默认；浅色对等。颜色经 ColorScheme.fromSeed 生成调性后覆盖关键语义色。
import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_dimens.dart';
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
  final textTertiary = isDark
      ? AppColors.textTertiary
      : AppColorsLight.textTertiary;

  // 解析当前亮度下的 token（子主题据此把 stock M3 拉回设计语言）。
  final bgBase = isDark ? AppColors.bgBase : AppColorsLight.bgBase;
  final surface1 = isDark ? AppColors.surface1 : AppColorsLight.surface1;
  final surface2 = isDark ? AppColors.surface2 : AppColorsLight.surface2;
  final surface3 = isDark ? AppColors.surface3 : AppColorsLight.surface3;
  final hairline = isDark ? AppColors.hairline : AppColorsLight.hairline;
  final hairlineStrong = isDark
      ? AppColors.hairlineStrong
      : AppColorsLight.hairlineStrong;
  final brand = isDark ? AppColors.brand : AppColorsLight.brand;
  final onBrand = isDark ? AppColors.onBrand : AppColorsLight.onBrand;

  final textTheme = TextTheme(
    displayLarge: AppType.display.copyWith(color: textPrimary),
    headlineMedium: AppType.h1.copyWith(color: textPrimary),
    titleLarge: AppType.h2.copyWith(color: textPrimary),
    titleMedium: AppType.titleM.copyWith(color: textPrimary),
    bodyMedium: AppType.body.copyWith(color: textPrimary),
    bodySmall: AppType.caption.copyWith(color: textSecondary),
    labelSmall: AppType.micro.copyWith(color: textSecondary),
  );

  final cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadius.md),
    side: BorderSide(color: hairline, width: AppStroke.hairline),
  );
  final fieldRadius = BorderRadius.circular(AppRadius.md);
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadius.md),
  );
  const buttonPadding = EdgeInsets.symmetric(
    horizontal: AppSpacing.base,
    vertical: AppSpacing.md,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: bgBase,
    canvasColor: bgBase,
    fontFamily: AppType.family,
    fontFamilyFallback: AppType.familyFallback,
    dividerColor: hairline,
    pageTransitionsTheme: _calmPageTransitions,
    splashFactory: InkSparkle.splashFactory,
    textTheme: textTheme,

    // 卡片：surface1 + hairline，无阴影、无 M3 色调抬升。
    cardTheme: CardThemeData(
      color: surface1,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: cardShape,
    ),

    // 顶栏：与底同色、无阴影、无滚动抬升染色。
    appBarTheme: AppBarTheme(
      backgroundColor: bgBase,
      foregroundColor: textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: AppType.h2.copyWith(color: textPrimary),
      iconTheme: IconThemeData(color: textSecondary),
    ),

    dividerTheme: DividerThemeData(
      color: hairline,
      thickness: AppStroke.hairline,
      space: AppStroke.hairline,
    ),

    iconTheme: IconThemeData(color: textSecondary),

    // 主动作：香槟金；文本/描边按钮用品牌前景。
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: brand,
        foregroundColor: onBrand,
        disabledBackgroundColor: hairline,
        disabledForegroundColor: textTertiary,
        textStyle: AppType.titleM,
        padding: buttonPadding,
        shape: buttonShape,
        elevation: 0,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: brand,
        textStyle: AppType.bodyStrong,
        shape: buttonShape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: textPrimary,
        textStyle: AppType.bodyStrong,
        side: BorderSide(color: hairlineStrong, width: AppStroke.hairline),
        padding: buttonPadding,
        shape: buttonShape,
      ),
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: brand,
      foregroundColor: onBrand,
      elevation: 2,
      focusElevation: 2,
      hoverElevation: 3,
      highlightElevation: 1,
      extendedTextStyle: AppType.titleM.copyWith(color: onBrand),
    ),

    // 输入框：填充 surface2 + hairline，聚焦描品牌金。
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface2,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.md,
      ),
      labelStyle: AppType.body.copyWith(color: textSecondary),
      hintStyle: AppType.body.copyWith(color: textTertiary),
      border: OutlineInputBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide(color: hairline, width: AppStroke.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide(color: hairline, width: AppStroke.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide(color: brand, width: AppStroke.focus),
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: surface2,
      side: BorderSide(color: hairline, width: AppStroke.hairline),
      labelStyle: AppType.caption.copyWith(color: textSecondary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xxs,
      ),
    ),

    listTileTheme: ListTileThemeData(
      iconColor: textSecondary,
      titleTextStyle: AppType.body.copyWith(color: textPrimary),
      subtitleTextStyle: AppType.caption.copyWith(color: textSecondary),
    ),

    // 底部导航：surface1，指示器用低调品牌染。
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface1,
      surfaceTintColor: Colors.transparent,
      indicatorColor: brand.withValues(alpha: isDark ? 0.22 : 0.16),
      elevation: 0,
      height: 64,
      labelTextStyle: WidgetStatePropertyAll(
        AppType.micro.copyWith(color: textSecondary),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? brand : textSecondary,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: surface1,
      selectedIconTheme: IconThemeData(color: brand),
      unselectedIconTheme: IconThemeData(color: textSecondary),
      selectedLabelTextStyle: AppType.micro.copyWith(color: brand),
      unselectedLabelTextStyle: AppType.micro.copyWith(color: textSecondary),
      indicatorColor: brand.withValues(alpha: isDark ? 0.22 : 0.16),
      useIndicator: true,
    ),

    // 浮层：菜单/Sheet/Dialog 用更高 surface + 覆盖阴影。
    dialogTheme: DialogThemeData(
      backgroundColor: surface3,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      titleTextStyle: AppType.h2.copyWith(color: textPrimary),
      contentTextStyle: AppType.body.copyWith(color: textSecondary),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface3,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      showDragHandle: true,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface3,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      textStyle: AppType.body.copyWith(color: textPrimary),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: surface3,
      contentTextStyle: AppType.body.copyWith(color: textPrimary),
      actionTextColor: brand,
      behavior: SnackBarBehavior.floating,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: surface3,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: hairline, width: AppStroke.hairline),
      ),
      textStyle: AppType.caption.copyWith(color: textPrimary),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: brand),
  );
}
