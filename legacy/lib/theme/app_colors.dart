import 'package:flutter/material.dart';

/// Visual language tokens — deep graphite / warm gray primary (from design doc)
class AppColors {
  // Backgrounds (dark primary)
  static const Color bgGraphite = Color(0xFF1C1C1E);
  static const Color bgWarmGray = Color(0xFF2A2826); // warm variant
  static const Color surface0 = Color(0xFF2C2C2E);
  static const Color surface1 = Color(0xFF38383A);
  static const Color surface2 = Color(0xFF48484A);

  // Text (high contrast but calm)
  static const Color textPrimary = Color(0xFFF2F2F7);
  static const Color textSecondary = Color(0xFF8E8E93);
  static const Color textTertiary = Color(0xFF636366);

  // Accents (trustworthy, restrained)
  static const Color primary = Color(0xFF0A84FF);     // system calm blue
  static const Color accentTeal = Color(0xFF64D2FF);  // subtle highlight
  static const Color positive = Color(0xFF30D158);    // muted green
  static const Color negative = Color(0xFFFF6961);    // muted (not screaming)

  // Chart specific
  static const Color chartLine = Color(0xFF0A84FF);
  static const Color chartAreaFill = Color(0x1A0A84FF); // 10% opacity
  static const Color chartGrid = Color(0xFF3A3A3C);
  static const Color chartAxis = Color(0xFF636366);

  // Status (muted, never jarring)
  static const Color statusInfo = Color(0xFF64D2FF);
  static const Color statusWarning = Color(0xFFFFD60A); // muted amber
  static const Color statusError = Color(0xFFFF6961);
  static const Color statusSuccess = Color(0xFF30D158);

  // Light / warm fallback (future expansion only — out of M1 scope)
  static const Color lightBg = Color(0xFFF2F2F7);
}

/// Usage rules (from design):
/// - Always use tokens; never hardcode hex outside this file.
/// - Status colors always paired with StatusBadge (icon + text).
/// - Charts use chartLine + subtle area.
