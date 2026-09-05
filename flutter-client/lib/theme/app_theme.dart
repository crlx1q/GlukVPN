import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

/// The single ThemeData for the app, built from [GlukColors].
///
/// The app uses Nunito 400-800 throughout, the same family as the Windows
/// client, so the two never look like different products. `google_fonts` fetches and
/// caches it on first launch and falls back to the platform sans-serif if the
/// device is offline before the first successful fetch - acceptable here
/// because the VPN is not connected at that point anyway.
class GlukTheme {
	GlukTheme._();

	/// Matches the mockup's status bar: light glyphs on the near-black canvas.
	static const systemOverlay = SystemUiOverlayStyle(
		statusBarColor: Colors.transparent,
		statusBarIconBrightness: Brightness.light,
		statusBarBrightness: Brightness.dark,
		systemNavigationBarColor: GlukColors.bg,
		systemNavigationBarIconBrightness: Brightness.light,
	);

	static ThemeData build() {
		final base = ThemeData.dark(useMaterial3: true);
		final text = _textTheme(base.textTheme);

		return base.copyWith(
			scaffoldBackgroundColor: GlukColors.bg,
			canvasColor: GlukColors.bg,
			colorScheme: const ColorScheme.dark(
				brightness: Brightness.dark,
				primary: GlukColors.violet,
				onPrimary: GlukColors.text0,
				secondary: GlukColors.violetLight,
				onSecondary: GlukColors.bg,
				tertiary: GlukColors.blue,
				surface: GlukColors.bg,
				onSurface: GlukColors.text0,
				error: GlukColors.danger,
				onError: GlukColors.text0,
			),
			textTheme: text,
			primaryTextTheme: text,
			iconTheme: const IconThemeData(color: GlukColors.text1, size: 20),
			splashFactory: InkSparkle.splashFactory,
			// The mockup has no Material app bars; screens draw their own header.
			appBarTheme: const AppBarTheme(
				backgroundColor: Colors.transparent,
				elevation: 0,
				scrolledUnderElevation: 0,
				systemOverlayStyle: systemOverlay,
				centerTitle: false,
			),
			dividerTheme: DividerThemeData(
				color: Colors.white.withOpacity(0.06),
				thickness: 1,
				space: 1,
			),
			inputDecorationTheme: InputDecorationTheme(
				filled: true,
				fillColor: Colors.white.withOpacity(0.04),
				hintStyle: text.bodyMedium?.copyWith(color: GlukColors.text2),
				labelStyle: text.labelLarge?.copyWith(color: GlukColors.text1),
				contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
				enabledBorder: _border(Colors.white.withOpacity(0.10)),
				focusedBorder: _border(GlukColors.violet.withOpacity(0.65), width: 1.4),
				errorBorder: _border(GlukColors.danger.withOpacity(0.7)),
				focusedErrorBorder: _border(GlukColors.danger, width: 1.4),
				errorStyle: text.bodySmall?.copyWith(color: GlukColors.danger),
			),
			snackBarTheme: SnackBarThemeData(
				behavior: SnackBarBehavior.floating,
				backgroundColor: const Color(0xFF1A1428),
				contentTextStyle: text.bodyMedium,
				shape: RoundedRectangleBorder(
					borderRadius: BorderRadius.circular(14),
					side: BorderSide(color: GlukColors.stroke),
				),
			),
			dialogTheme: DialogThemeData(
				backgroundColor: const Color(0xFF120D1E),
				surfaceTintColor: Colors.transparent,
				shape: RoundedRectangleBorder(
					borderRadius: BorderRadius.circular(22),
					side: BorderSide(color: GlukColors.stroke),
				),
				titleTextStyle: text.titleMedium,
				contentTextStyle: text.bodyMedium?.copyWith(color: GlukColors.text1),
			),
			progressIndicatorTheme: const ProgressIndicatorThemeData(
				color: GlukColors.violetLight,
				linearTrackColor: Color(0x22FFFFFF),
			),
			switchTheme: SwitchThemeData(
				thumbColor: WidgetStateProperty.resolveWith(
					(states) => states.contains(WidgetState.selected)
							? GlukColors.violetLight
							: GlukColors.text2,
				),
				trackColor: WidgetStateProperty.resolveWith(
					(states) => states.contains(WidgetState.selected)
							? GlukColors.violet.withOpacity(0.45)
							: Colors.white.withOpacity(0.08),
				),
				trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
			),
		);
	}

	static OutlineInputBorder _border(Color color, {double width = 1}) {
		return OutlineInputBorder(
			borderRadius: BorderRadius.circular(16),
			borderSide: BorderSide(color: color, width: width),
		);
	}

	/// Type scale transcribed from the mockup's CSS.
	static TextTheme _textTheme(TextTheme base) {
		final nunito = GoogleFonts.nunitoTextTheme(base);
		return nunito.copyWith(
			// `.ob-head h1` - 25px / 700 / line-height 1.24
			headlineMedium: nunito.headlineMedium?.copyWith(
				fontSize: 25,
				fontWeight: FontWeight.w700,
				height: 1.24,
				color: GlukColors.text0,
				letterSpacing: -0.2,
			),
			// Screen titles.
			titleLarge: nunito.titleLarge?.copyWith(
				fontSize: 19,
				fontWeight: FontWeight.w700,
				color: GlukColors.text0,
			),
			titleMedium: nunito.titleMedium?.copyWith(
				fontSize: 15,
				fontWeight: FontWeight.w600,
				color: GlukColors.text0,
			),
			// `.statusbar` - 14px / 600
			titleSmall: nunito.titleSmall?.copyWith(
				fontSize: 14,
				fontWeight: FontWeight.w600,
				color: GlukColors.text0,
			),
			bodyLarge: nunito.bodyLarge?.copyWith(
				fontSize: 15,
				fontWeight: FontWeight.w500,
				color: GlukColors.text0,
			),
			bodyMedium: nunito.bodyMedium?.copyWith(
				fontSize: 13.5,
				fontWeight: FontWeight.w400,
				height: 1.45,
				color: GlukColors.text1,
			),
			bodySmall: nunito.bodySmall?.copyWith(
				fontSize: 12,
				fontWeight: FontWeight.w500,
				color: GlukColors.text2,
			),
			// `.cell-value` - 15px / 700 / tabular numbers, so the duration and
			// traffic readouts do not jitter while they tick.
			labelLarge: nunito.labelLarge?.copyWith(
				fontSize: 15,
				fontWeight: FontWeight.w700,
				color: GlukColors.text0,
				fontFeatures: const [FontFeature.tabularFigures()],
			),
			// `.cell-label` - 10px / 700 / letter-spacing .06em / uppercase
			labelMedium: nunito.labelMedium?.copyWith(
				fontSize: 10,
				fontWeight: FontWeight.w700,
				letterSpacing: 0.6,
				color: GlukColors.text2,
			),
			// `.badge` - 11.5px / 700
			labelSmall: nunito.labelSmall?.copyWith(
				fontSize: 11.5,
				fontWeight: FontWeight.w700,
				letterSpacing: 0.2,
				color: GlukColors.violetLight,
			),
		);
	}
}
