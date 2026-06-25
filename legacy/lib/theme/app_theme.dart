import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_typography.dart';

/// Main ThemeData for the app (dark/graphite primary)
ThemeData buildAppTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bgGraphite,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.primary,
      surface: AppColors.surface0,
    ),
    textTheme: AppTypography.textTheme,
    useMaterial3: true,
    // Extend with card theme, etc. as needed from the full design doc
  );
}
