import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// Builds the AUTOMETA dark (default) and light themes.
class AutometaTheme {
  const AutometaTheme._();

  static ThemeData get dark => _build(Brightness.dark);
  static ThemeData get light => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final bool isDark = brightness == Brightness.dark;

    final Color background =
        isDark ? AutometaColors.darkBackground : AutometaColors.lightBackground;
    final Color surface = isDark ? AutometaColors.darkSurface : AutometaColors.lightSurface;
    final Color surfaceRaised =
        isDark ? AutometaColors.darkSurfaceRaised : AutometaColors.lightSurfaceRaised;
    final Color surfaceHigh =
        isDark ? AutometaColors.darkSurfaceHigh : AutometaColors.lightSurfaceHigh;
    final Color border = isDark ? AutometaColors.darkBorder : AutometaColors.lightBorder;
    final Color borderStrong =
        isDark ? AutometaColors.darkBorderStrong : AutometaColors.lightBorderStrong;
    final Color textPrimary =
        isDark ? AutometaColors.darkTextPrimary : AutometaColors.lightTextPrimary;
    final Color textSecondary =
        isDark ? AutometaColors.darkTextSecondary : AutometaColors.lightTextSecondary;
    final Color textTertiary =
        isDark ? AutometaColors.darkTextTertiary : AutometaColors.lightTextTertiary;

    final ColorScheme scheme = ColorScheme(
      brightness: brightness,
      primary: AutometaColors.accentDim,
      onPrimary: Colors.white,
      secondary: AutometaColors.secondary,
      onSecondary: Colors.white,
      error: AutometaColors.danger,
      onError: Colors.white,
      surface: surface,
      onSurface: textPrimary,
      surfaceContainerHighest: surfaceHigh,
      onSurfaceVariant: textSecondary,
      outline: border,
      outlineVariant: border,
    );

    final TextTheme textTheme = TextTheme(
      displaySmall: _text(30, FontWeight.w700, textPrimary, -0.5),
      headlineMedium: _text(24, FontWeight.w700, textPrimary, -0.3),
      headlineSmall: _text(20, FontWeight.w700, textPrimary, -0.2),
      titleLarge: _text(18, FontWeight.w600, textPrimary),
      titleMedium: _text(16, FontWeight.w600, textPrimary),
      titleSmall: _text(14, FontWeight.w600, textPrimary),
      bodyLarge: _text(16, FontWeight.w400, textPrimary),
      bodyMedium: _text(14, FontWeight.w400, textSecondary),
      bodySmall: _text(12, FontWeight.w400, textTertiary),
      labelLarge: _text(14, FontWeight.w600, textPrimary, 0.2),
      labelMedium: _text(12, FontWeight.w600, textSecondary, 0.4),
      labelSmall: _text(11, FontWeight.w600, textTertiary, 0.6),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      splashFactory: InkSparkle.splashFactory,
      textTheme: textTheme,
      visualDensity: VisualDensity.standard,
      dividerColor: border,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(letterSpacing: 1.4),
      ),
      cardTheme: CardThemeData(
        color: surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AutometaSpacing.radiusLg),
          side: BorderSide(color: border),
        ),
      ),
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      listTileTheme: ListTileThemeData(
        iconColor: textSecondary,
        textColor: textPrimary,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AutometaSpacing.lg,
          vertical: AutometaSpacing.xs,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? AutometaColors.darkSurfaceHigh : AutometaColors.lightSurfaceHigh,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AutometaSpacing.lg,
          vertical: AutometaSpacing.md,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(color: textTertiary),
        labelStyle: textTheme.labelLarge?.copyWith(color: textSecondary),
        border: _inputBorder(border),
        enabledBorder: _inputBorder(border),
        focusedBorder: _inputBorder(AutometaColors.accent, width: 1.4),
        errorBorder: _inputBorder(AutometaColors.danger),
        focusedErrorBorder: _inputBorder(AutometaColors.danger, width: 1.4),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AutometaColors.accentDeep,
          foregroundColor: AutometaColors.accent,
          minimumSize: const Size.fromHeight(AutometaSpacing.touchTarget),
          textStyle: textTheme.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AutometaSpacing.radiusMd),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          minimumSize: const Size.fromHeight(AutometaSpacing.touchTarget),
          side: BorderSide(color: borderStrong),
          textStyle: textTheme.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AutometaSpacing.radiusMd),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AutometaColors.accentDim,
          minimumSize: const Size(0, AutometaSpacing.touchTarget),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceHigh,
        side: BorderSide(color: border),
        labelStyle: textTheme.labelMedium?.copyWith(color: textSecondary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceHigh,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AutometaSpacing.radiusMd),
          side: BorderSide(color: border),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AutometaSpacing.radiusXl),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AutometaSpacing.radiusLg),
          side: BorderSide(color: border),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AutometaColors.accent.withValues(alpha: 0.12),
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? textTheme.labelMedium?.copyWith(color: AutometaColors.accent)
              : textTheme.labelMedium,
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (Set<WidgetState> states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? AutometaColors.accent
                : textTertiary,
            size: 22,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> states) =>
              states.contains(WidgetState.selected) ? AutometaColors.accent : textTertiary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? AutometaColors.accentDeep
              : surfaceHigh,
        ),
        trackOutlineColor: WidgetStateProperty.all(border),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AutometaColors.accent,
        linearTrackColor: AutometaColors.darkSurfaceHigh,
      ),
      extensions: <ThemeExtension<dynamic>>[
        isDark ? AutometaSemanticColors.dark : AutometaSemanticColors.light,
      ],
    );
  }

  static TextStyle _text(
    double size,
    FontWeight weight,
    Color color, [
    double? letterSpacing,
  ]) =>
      TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
        height: 1.32,
      );

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(AutometaSpacing.radiusMd),
        borderSide: BorderSide(color: color, width: width),
      );
}

/// Semantic colours that flip with brightness, exposed through the theme so
/// widgets never hard-code a palette branch.
@immutable
class AutometaSemanticColors extends ThemeExtension<AutometaSemanticColors> {
  const AutometaSemanticColors({
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceHigh,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
  });

  final Color background;
  final Color surface;
  final Color surfaceRaised;
  final Color surfaceHigh;
  final Color border;
  final Color borderStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  static const AutometaSemanticColors dark = AutometaSemanticColors(
    background: AutometaColors.darkBackground,
    surface: AutometaColors.darkSurface,
    surfaceRaised: AutometaColors.darkSurfaceRaised,
    surfaceHigh: AutometaColors.darkSurfaceHigh,
    border: AutometaColors.darkBorder,
    borderStrong: AutometaColors.darkBorderStrong,
    textPrimary: AutometaColors.darkTextPrimary,
    textSecondary: AutometaColors.darkTextSecondary,
    textTertiary: AutometaColors.darkTextTertiary,
  );

  static const AutometaSemanticColors light = AutometaSemanticColors(
    background: AutometaColors.lightBackground,
    surface: AutometaColors.lightSurface,
    surfaceRaised: AutometaColors.lightSurfaceRaised,
    surfaceHigh: AutometaColors.lightSurfaceHigh,
    border: AutometaColors.lightBorder,
    borderStrong: AutometaColors.lightBorderStrong,
    textPrimary: AutometaColors.lightTextPrimary,
    textSecondary: AutometaColors.lightTextSecondary,
    textTertiary: AutometaColors.lightTextTertiary,
  );

  static AutometaSemanticColors of(BuildContext context) =>
      Theme.of(context).extension<AutometaSemanticColors>() ?? dark;

  @override
  AutometaSemanticColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceHigh,
    Color? border,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
  }) =>
      AutometaSemanticColors(
        background: background ?? this.background,
        surface: surface ?? this.surface,
        surfaceRaised: surfaceRaised ?? this.surfaceRaised,
        surfaceHigh: surfaceHigh ?? this.surfaceHigh,
        border: border ?? this.border,
        borderStrong: borderStrong ?? this.borderStrong,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
        textTertiary: textTertiary ?? this.textTertiary,
      );

  @override
  AutometaSemanticColors lerp(covariant AutometaSemanticColors? other, double t) {
    if (other == null) return this;
    return AutometaSemanticColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      surfaceHigh: Color.lerp(surfaceHigh, other.surfaceHigh, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
    );
  }
}
