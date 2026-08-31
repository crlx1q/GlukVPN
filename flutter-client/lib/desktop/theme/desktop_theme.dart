import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/tokens.dart';

/// Desktop-only visual tokens.
///
/// The mobile [GlukColors] palette stays the single source of truth for hue;
/// these are the extra surface values a 1180x740 window needs and a phone
/// does not (card fills, hairlines, rail widths).
class DesktopTokens {
  const DesktopTokens._();

  /// Main card fill. Slightly lifted from [GlukColors.pageBg] so cards read as
  /// panels without a visible border.
  static const Color card = Color(0xFF0C0916);
  static const Color cardRaised = Color(0xFF120E1E);
  static const Color cardHover = Color(0xFF17122A);
  static const Color sidebar = Color(0xFF08060F);

  /// 8% white. Used for the 1px separators inside the CONNECTION card.
  static const Color hairline = Color(0x14FFFFFF);
  static const Color cardBorder = Color(0x12FFFFFF);

  static const double cardRadius = 22;
  static const double innerRadius = 16;
  static const double pillRadius = 999;

  static const double sidebarWidth = 236;
  static const double rightRailWidth = 304;
  static const double gutter = 16;
  static const double pagePadding = 18;

  /// Windows ships Segoe UI everywhere; Poppins is the mobile family and is
  /// already cached by google_fonts on most machines. Either is an acceptable
  /// stand-in for the ~200 ms before Nunito arrives on a cold profile.
  static const List<String> fontFallback = <String>[
    'Segoe UI Variable Text',
    'Segoe UI',
    'Poppins',
    'Arial',
  ];

  static List<BoxShadow> glow(
    Color color, {
    double blur = 26,
    double spread = 0,
    double opacity = 0.30,
  }) {
    return <BoxShadow>[
      BoxShadow(
        color: color.withOpacity(opacity),
        blurRadius: blur,
        spreadRadius: spread,
      ),
    ];
  }

  /// Standard card decoration used by every panel in the desktop shell.
  static BoxDecoration cardDecoration({
    Color? color,
    double radius = cardRadius,
    Color? borderColor,
  }) {
    return BoxDecoration(
      color: color ?? card,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: borderColor ?? cardBorder, width: 1),
    );
  }
}

/// Builds the desktop [ThemeData] and, more importantly, guarantees that no
/// text is ever rendered with Flutter's "you forgot a Material ancestor"
/// fallback style.
///
/// That fallback is the cause of the yellow double underlines that appeared
/// under every label in the first desktop build: `MaterialApp` installs an
/// error `DefaultTextStyle` carrying `decoration: TextDecoration.underline`
/// with a yellow decoration colour, and any `Text` that supplies its own
/// colour and size but no `decoration` merges that underline in. Wrapping the
/// whole app in a transparent [Material] (see [wrap]) replaces the fallback
/// with a real style, and every text style below sets
/// `decoration: TextDecoration.none` as a second line of defence.
class DesktopTheme {
  const DesktopTheme._();

  static ThemeData build() {
    final ThemeData base = ThemeData.dark(useMaterial3: true);
    final TextTheme text = textTheme(base.textTheme);

    return base.copyWith(
      scaffoldBackgroundColor: GlukColors.pageBg,
      canvasColor: GlukColors.pageBg,
      textTheme: text,
      primaryTextTheme: text,
      colorScheme: base.colorScheme.copyWith(
        primary: GlukColors.violet,
        secondary: GlukColors.violetLight,
        surface: DesktopTokens.card,
        error: GlukColors.danger,
        onPrimary: Colors.white,
        onSurface: GlukColors.text0,
      ),
      dividerColor: DesktopTokens.hairline,
      dividerTheme: const DividerThemeData(
        color: DesktopTokens.hairline,
        thickness: 1,
        space: 1,
      ),
      // Desktop pointers do not need ink ripples; they make the glass look
      // muddy on click.
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      hoverColor: Colors.white.withOpacity(0.04),
      focusColor: GlukColors.violet.withOpacity(0.20),
      iconTheme: const IconThemeData(color: GlukColors.text1, size: 20),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: DesktopTokens.cardRaised,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: DesktopTokens.cardBorder),
        ),
        textStyle: _scrub(
          GoogleFonts.nunito(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: GlukColors.text0,
          ),
        ),
      ),
    );
  }

  /// Nunito type scale, transposed from the mobile Poppins scale so the two
  /// clients keep the same rhythm and only the family differs.
  static TextTheme textTheme(TextTheme base) {
    final TextTheme n = GoogleFonts.nunitoTextTheme(base);

    return n.copyWith(
      // Sidebar wordmark.
      headlineSmall: _scrub(n.headlineSmall).copyWith(
        fontSize: 21,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.2,
        color: GlukColors.text0,
      ),
      // Screen titles ("Servers", "Settings").
      titleLarge: _scrub(n.titleLarge).copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.2,
        color: GlukColors.text0,
      ),
      // Card values: VPN IP, DURATION, PING, traffic counters.
      titleMedium: _scrub(n.titleMedium).copyWith(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        color: GlukColors.text0,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
      // Row titles in Settings and the server list.
      titleSmall: _scrub(n.titleSmall).copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: GlukColors.text0,
      ),
      bodyLarge: _scrub(n.bodyLarge).copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: GlukColors.text0,
      ),
      bodyMedium: _scrub(n.bodyMedium).copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: GlukColors.text0,
      ),
      // Secondary/help lines under a setting.
      bodySmall: _scrub(n.bodySmall).copyWith(
        fontSize: 12.5,
        fontWeight: FontWeight.w500,
        height: 1.35,
        color: GlukColors.text1,
      ),
      labelLarge: _scrub(n.labelLarge).copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: GlukColors.text0,
      ),
      // Section captions: CONNECTION, TRAFFIC, GENERAL, VPN.
      labelMedium: _scrub(n.labelMedium).copyWith(
        fontSize: 10.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.1,
        color: GlukColors.text2,
      ),
      labelSmall: _scrub(n.labelSmall).copyWith(
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.8,
        color: GlukColors.text1,
      ),
    );
  }

  /// Strips any inherited decoration and pins the Windows fallback chain.
  static TextStyle _scrub(TextStyle? style) {
    return (style ?? const TextStyle()).copyWith(
      decoration: TextDecoration.none,
      decorationColor: Colors.transparent,
      decorationThickness: 0,
      fontFamilyFallback: DesktopTokens.fontFallback,
    );
  }

  /// Wraps the whole widget tree so that:
  ///   1. a [Material] ancestor always exists (kills the underline fallback),
  ///   2. the ambient text style is a real one instead of the error style,
  ///   3. Windows text scaling cannot blow the fixed desktop layout apart.
  ///
  /// Install it with `MaterialApp(builder: DesktopTheme.appBuilder)`.
  static Widget appBuilder(BuildContext context, Widget? child) {
    final TextStyle ambient =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();

    return MediaQuery.withClampedTextScaling(
      minScaleFactor: 1.0,
      maxScaleFactor: 1.15,
      child: Material(
        type: MaterialType.transparency,
        textStyle: ambient,
        child: DefaultTextStyle(
          style: ambient,
          child: DefaultSelectionStyle(
            cursorColor: GlukColors.violetLight,
            selectionColor: GlukColors.violet.withOpacity(0.35),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
