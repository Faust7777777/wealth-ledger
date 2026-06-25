import 'package:flutter/material.dart';

/// Spacing system (4px base — aligns with high-polish restrained apps)
class AppSpacing {
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 16.0;
  static const double lg = 24.0;
  static const double xl = 32.0;
  static const double xxl = 48.0;

  // Component padding
  static const EdgeInsets cardPadding = EdgeInsets.all(md);
  static const EdgeInsets heroPadding = EdgeInsets.symmetric(
    horizontal: lg,
    vertical: xl,
  );
  static const EdgeInsets listRowPadding = EdgeInsets.symmetric(
    horizontal: md,
    vertical: sm,
  );

  // Desktop columns (approximate)
  static const double sidebarWidth = 260.0;
  static const double rightPanelWidth = 280.0;
}
