import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Typography — Inter explicit cross-platform choice (Wonderous-quality, consistent)
/// 48px hero for net worth (sole visual protagonist)
class AppTypography {
  static TextTheme get textTheme => TextTheme(
        // Hero / Net worth display — THE visual hero
        displayLarge: GoogleFonts.inter(
          fontSize: 48,
          fontWeight: FontWeight.w600,
          letterSpacing: -1.5,
          height: 1.1,
          color: const Color(0xFFF2F2F7),
        ),
        // Large headings
        headlineLarge: GoogleFonts.inter(
          fontSize: 28,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.5,
          height: 1.2,
        ),
        headlineMedium: GoogleFonts.inter(
          fontSize: 22,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.3,
        ),
        // Body
        bodyLarge: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          height: 1.5,
        ),
        bodyMedium: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          height: 1.4,
        ),
        // Captions / labels (quiet)
        labelSmall: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.3,
          color: const Color(0xFF8E8E93),
        ),
        // Transaction row meta
        bodySmall: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          height: 1.3,
          color: const Color(0xFF8E8E93),
        ),
      );
}
