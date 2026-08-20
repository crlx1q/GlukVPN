import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The GlukVPN mark: a dark violet rounded tile with a key glyph, drawn with a
/// painter instead of shipping `assets/logo.png`.
///
/// Why vector and not the real PNG: the release APK is built by GitHub Actions
/// from the public repo, and the publish path used for this project carries text
/// only, so a binary asset can never reach CI. A declared-but-missing asset
/// makes `flutter build` fail outright, which is worse than a redrawn mark. The
/// geometry and the glow below match `logo.png` and the `.ob-logo img` rule in
/// the design mock-up (56 px tile, 16 px radius, shadow 0 8px 30px
/// rgba(124, 92, 246, 0.45)).
///
/// To switch back to the real artwork later: add `assets/logo.png` to the
/// package, declare it under `flutter: assets:` in pubspec.yaml and replace the
/// [CustomPaint] below with `Image.asset('assets/logo.png')`. Nothing else in
/// the app needs to change.
class GlukLogo extends StatelessWidget {
	const GlukLogo({
		super.key,
		this.size = 56,
		this.radius,
		this.glow = true,
	});

	/// Side of the square tile in logical pixels.
	final double size;

	/// Corner radius. Defaults to the mock-up ratio (16 / 56 of the side).
	final double? radius;

	/// Violet drop shadow. Turn it off inside dense rows (app bar, list tiles).
	final bool glow;

	@override
	Widget build(BuildContext context) {
		final double corner = radius ?? size * (GlukSizes.logoRadius / 56);
		return Container(
			width: size,
			height: size,
			decoration: BoxDecoration(
				borderRadius: BorderRadius.circular(corner),
				gradient: const LinearGradient(
					begin: Alignment.topLeft,
					end: Alignment.bottomRight,
					colors: <Color>[Color(0xFF2A1F53), Color(0xFF120C24)],
				),
				border: Border.all(color: GlukColors.stroke, width: 0.8),
				boxShadow: glow
						? <BoxShadow>[
								BoxShadow(
									color: const Color(0xFF7C5CF6).withOpacity(0.45),
									blurRadius: size * (30 / 56),
									offset: Offset(0, size * (8 / 56)),
								),
							]
						: null,
			),
			child: CustomPaint(
				painter: _GlukKeyPainter(),
				size: Size.square(size),
			),
		);
	}
}

/// The key glyph: a ring in the upper left, a shaft running to the lower right
/// and two teeth on its upper edge. All coordinates are fractions of the side,
/// so the mark stays crisp at 26 px and at 96 px.
class _GlukKeyPainter extends CustomPainter {
	@override
	void paint(Canvas canvas, Size size) {
		final double s = size.shortestSide;
		if (s <= 0) {
			return;
		}

		final Shader shader = const LinearGradient(
			begin: Alignment.topLeft,
			end: Alignment.bottomRight,
			colors: <Color>[GlukColors.violetLight, GlukColors.blue],
		).createShader(Rect.fromLTWH(0, 0, s, s));

		final Paint stroke = Paint()
			..style = PaintingStyle.stroke
			..strokeCap = StrokeCap.round
			..strokeJoin = StrokeJoin.round
			..isAntiAlias = true
			..shader = shader
			..strokeWidth = s * 0.105;

		// Ring.
		canvas.drawCircle(Offset(s * 0.36, s * 0.36), s * 0.145, stroke);

		// Shaft, on the ring's diagonal.
		const double diagonal = 0.7071067811865476;
		final Offset shaftStart = Offset(s * 0.468, s * 0.468);
		final Offset shaftEnd = Offset(s * 0.760, s * 0.760);
		canvas.drawLine(shaftStart, shaftEnd, stroke);

		// Teeth: perpendicular to the shaft, pointing up and to the right.
		final double shaftLength = (shaftEnd - shaftStart).distance;
		const Offset along = Offset(diagonal, diagonal);
		const Offset across = Offset(diagonal, -diagonal);
		final Paint tooth = Paint()
			..style = PaintingStyle.stroke
			..strokeCap = StrokeCap.round
			..isAntiAlias = true
			..shader = shader
			..strokeWidth = s * 0.092;
		for (final List<double> spec in const <List<double>>[
			<double>[0.46, 0.150],
			<double>[0.80, 0.110],
		]) {
			final Offset base = shaftStart + along * (shaftLength * spec[0]);
			canvas.drawLine(base, base + across * (s * spec[1]), tooth);
		}
	}

	@override
	bool shouldRepaint(covariant _GlukKeyPainter oldDelegate) => false;
}
