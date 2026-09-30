// Design tokens for AUTOMETA.
//
// The product should read as "premium automation software", not a gaming RGB
// panel: dark neutral base, one electric accent, one restrained secondary,
// glow used sparingly (only on the brand mark and active-state indicators).
import 'package:flutter/material.dart';

class AutometaColors {
  const AutometaColors._();

  // --- Dark palette (default) ---
  static const Color darkBackground = Color(0xFF07090C);
  static const Color darkSurface = Color(0xFF0E1218);
  static const Color darkSurfaceRaised = Color(0xFF141A22);
  static const Color darkSurfaceHigh = Color(0xFF1B232D);
  static const Color darkBorder = Color(0xFF222C38);
  static const Color darkBorderStrong = Color(0xFF31404F);

  // --- Light palette (optional) ---
  static const Color lightBackground = Color(0xFFF4F6F9);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceRaised = Color(0xFFFFFFFF);
  static const Color lightSurfaceHigh = Color(0xFFEDF1F6);
  static const Color lightBorder = Color(0xFFDFE5ED);
  static const Color lightBorderStrong = Color(0xFFC3CDDB);

  // --- Brand ---
  static const Color accent = Color(0xFF22E3D3); // electric cyan / teal
  static const Color accentDim = Color(0xFF12A79C);
  static const Color accentDeep = Color(0xFF0A5F5A);
  static const Color secondary = Color(0xFF8B7CFF); // subtle violet
  static const Color secondaryDeep = Color(0xFF3B3480);

  // --- Semantic ---
  static const Color success = Color(0xFF37D67A);
  static const Color warning = Color(0xFFFFB020);
  static const Color danger = Color(0xFFFF5C63);
  static const Color info = Color(0xFF4EA8FF);
  static const Color neutral = Color(0xFF8A97A6);

  // --- Text on dark ---
  static const Color darkTextPrimary = Color(0xFFEDF2F7);
  static const Color darkTextSecondary = Color(0xFFA7B4C2);
  static const Color darkTextTertiary = Color(0xFF6C7B8B);

  // --- Text on light ---
  static const Color lightTextPrimary = Color(0xFF0D1319);
  static const Color lightTextSecondary = Color(0xFF4A5866);
  static const Color lightTextTertiary = Color(0xFF7A8898);
}

/// Spacing / radius scale. Everything in the UI derives from these so screens
/// stay consistent and adapt to small and large phones.
class AutometaSpacing {
  const AutometaSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  static const double radiusSm = 10;
  static const double radiusMd = 14;
  static const double radiusLg = 20;
  static const double radiusXl = 28;

  /// Minimum touch target recommended by the Material accessibility guidance.
  static const double touchTarget = 48;

  /// Horizontal page padding, widened on large phones / small tablets.
  static double page(BuildContext context) {
    final double width = MediaQuery.sizeOf(context).width;
    if (width >= 900) return 64;
    if (width >= 600) return 32;
    return lg;
  }
}

class AutometaShadows {
  const AutometaShadows._();

  static List<BoxShadow> card(Color glowColor, {double opacity = 0.10}) => <BoxShadow>[
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.28),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
        BoxShadow(
          color: glowColor.withValues(alpha: opacity),
          blurRadius: 40,
          offset: const Offset(0, 0),
        ),
      ];
}
