import 'package:flutter/material.dart';

/// Design tokens taken verbatim from the approved mockups
/// (`gluk_vpn_v5_connection.html`, `gluk_vpn_v4_purple.html`).
///
/// Every value here has a counterpart in the HTML `:root` block. Keep them in
/// sync - if a colour changes in the mockup, change it here, not in a widget.
class GlukColors {
	GlukColors._();

	/// `--bg` - the phone canvas.
	static const bg = Color(0xFF0A0714);

	/// The page behind the device frame in the mockup; used for system chrome.
	static const pageBg = Color(0xFF05040A);

	/// `--violet` - primary brand colour (the logo key).
	static const violet = Color(0xFF8B5CF6);

	/// `--violet-2`
	static const violet2 = Color(0xFF6D4DE0);

	/// `--indigo`
	static const indigo = Color(0xFF4F3FD6);

	/// `--blue`
	static const blue = Color(0xFF4F7CFF);

	/// `--violet-light` - accents, arcs, active nav item.
	static const violetLight = Color(0xFFC4B5FD);

	/// `--amber` - reserved for the BETA channel badge.
	static const amber = Color(0xFFF0B567);

	/// `--text-0` / `--text-1` / `--text-2`
	static const text0 = Color(0xFFF5F3FB);
	static const text1 = Color(0xFF9994AB);
	static const text2 = Color(0xFF5C5770);

	/// Soft green for an established tunnel. Deliberately not a neon green:
	/// rendered at ~70% opacity it reads as "connected" without shouting.
	static const connected = Color(0xFF3DDC97);

	/// Errors and destructive actions.
	static const danger = Color(0xFFFF6B6B);

	/// The dotted world map's dot colour in the mockup SVG.
	static const mapDot = Color(0xFF8B7CF6);

	/// Card surfaces. The mockup's `--glass` is `rgba(255,255,255,0.05)`: a thin
	/// film, not a panel. These are deliberately low-alpha so the dotted world
	/// keeps reading through every card - glass, not a dark rectangle.
	static const cell = Color(0x59120E1C);

	/// The nav bar sits over the busiest part of the map and carries small
	/// labels, so it gets a little more body than a metric cell - but still far
	/// less than an opaque surface.
	static const navbar = Color(0x66120E1C);

	/// `--glass` and `--stroke`.
	static Color get glass => Colors.white.withOpacity(0.05);
	static Color get stroke => Colors.white.withOpacity(0.14);

	/// Power-button gradient stops (`.power-btn` radial gradient).
	static const powerOuter = Color(0xFF201A30);
	static const powerInner = Color(0xFF0A0812);

	/// The idle power glyph stroke.
	static const powerGlyph = Color(0xFF6A6478);
}

/// Gradients reproduced from the mockup.
class GlukGradients {
	GlukGradients._();

	/// `.arrow` on the onboarding button: `135deg, violet-light -> blue`.
	static const arrow = LinearGradient(
		begin: Alignment.topLeft,
		end: Alignment.bottomRight,
		colors: [GlukColors.violetLight, GlukColors.blue],
	);

	/// `.blob-outer`: `linear-gradient(150deg, violet-light, indigo)`.
	///
	/// A CSS angle of 150deg points along (sin150, -cos150) = (0.5, 0.866) in
	/// screen space, so the stops run from the upper left to the lower right.
	static const blobOuter = LinearGradient(
		begin: Alignment(-0.5, -0.866),
		end: Alignment(0.5, 0.866),
		colors: [GlukColors.violetLight, GlukColors.indigo],
	);

	/// `.blob-inner-ring`: `linear-gradient(320deg, blue, violet)`.
	/// 320deg points along (-0.643, -0.766), i.e. up and to the left.
	static const blobInner = LinearGradient(
		begin: Alignment(0.643, 0.766),
		end: Alignment(-0.643, -0.766),
		colors: [GlukColors.blue, GlukColors.violet],
	);

	/// `#pathGrad` used by the connection arc.
	static const connectionPath = LinearGradient(
		colors: [GlukColors.violetLight, GlukColors.blue],
	);

	/// `.power-btn` radial gradient, centred at 35% / 30%.
	static const powerButton = RadialGradient(
		center: Alignment(-0.3, -0.4),
		radius: 0.95,
		colors: [GlukColors.powerOuter, GlukColors.powerInner],
		stops: [0.0, 0.75],
	);

	/// The globe halo on onboarding.
	static RadialGradient get globeHalo => RadialGradient(
		colors: [
			GlukColors.violet.withOpacity(0.35),
			GlukColors.blue.withOpacity(0.12),
			Colors.transparent,
		],
		stops: const [0.0, 0.45, 1.0],
	);
}

/// Spacing, radii and sizes lifted from the mockup's CSS.
class GlukSizes {
	GlukSizes._();

	/// Horizontal page padding (`.ob-head`, `.grid`, `.navbar` margins).
	static const pagePadding = 24.0;

	/// `.cell` radius.
	static const cellRadius = 15.0;

	/// `backdrop-filter: blur(...)` on the mockup's cards.
	///
	/// One value for every surface in the app, and a small one. A card blurs
	/// whatever is behind it, so the same panel looked frosted over the dense
	/// part of the map and clear over the empty part - which read as two
	/// different materials on one screen. At this radius the world stays legible
	/// through every card and the difference disappears; the fill in
	/// [GlukColors.cell] carries the contrast instead.
	static const glassBlur = 2.5;

	/// The nav bar sits over the busiest part of the map and carries labels, so
	/// it gets a little more - still nowhere near frosted.
	static const navBlur = 6.0;

	/// `.traffic` radius.
	static const trafficRadius = 16.0;

	/// `.navbar` radius.
	static const navRadius = 18.0;

	/// `.ob-logo img` radius.
	static const logoRadius = 16.0;

	/// The globe on onboarding.
	static const globe = 236.0;

	/// `.globe-halo`.
	static const globeHalo = 300.0;

	/// `.power-btn`.
	static const powerButton = 150.0;

	/// `.blob-outer` / `.blob-inner-ring`.
	static const blob = 210.0;

	/// `.blob-glow`.
	static const blobGlow = 260.0;

	/// `.map-stage` height.
	static const mapStage = 400.0;

	/// `.flag-circle`, `.radio`.
	static const flagCircle = 26.0;
	static const radio = 26.0;

	/// `.back-btn`.
	static const backButton = 42.0;
}

/// Animation durations from the mockup's keyframes. Grouped here so the
/// battery-saver path can scale or disable them in one place.
class GlukMotion {
	GlukMotion._();

	/// `.screen` transition: `opacity .4s ease, transform .4s ease`.
	static const screen = Duration(milliseconds: 400);

	/// The 24 px slide that accompanies a screen change.
	static const screenSlide = 24.0;

	/// `spinGlobe 30s linear infinite`.
	static const globeSpin = Duration(seconds: 30);

	/// `haloPulse 4.5s`.
	static const haloPulse = Duration(milliseconds: 4500);

	/// `dash 2s` on the onboarding arc, `dashFlow 1.4s` on the connection arc.
	static const arcDash = Duration(seconds: 2);
	static const connectionDash = Duration(milliseconds: 1400);

	/// `pulseRing 2.2s` / `mapPulse 2.4s`.
	static const nodePulse = Duration(milliseconds: 2200);
	static const mapPulse = Duration(milliseconds: 2400);

	/// `morph1` / `morph2` on the connecting blob: `7s`.
	static const blobMorph = Duration(seconds: 7);

	/// `glowPulse 3.6s`.
	static const glowPulse = Duration(milliseconds: 3600);

	/// `blink 1.8s` on the status badge.
	static const badgeBlink = Duration(milliseconds: 1800);
}

class NoticeTone {
  static const info = GlukColors.violet;
  static const warning = GlukColors.amber;
  static const danger = GlukColors.danger;
}

