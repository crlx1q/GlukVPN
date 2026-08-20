import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Google and Telegram marks drawn as vectors.
///
/// Both are reconstructions of the official artwork geometry and palettes
/// (Google: #EA4335 / #FBBC05 / #34A853 / #4285F4 - Telegram: #37AEE2), so the
/// buttons look like the real thing at any density without bundling a
/// third-party binary asset or pulling in an SVG runtime.
class GoogleMark extends StatelessWidget {
  const GoogleMark({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: const _GoogleMarkPainter(),
      );
}

class _GoogleMarkPainter extends CustomPainter {
  const _GoogleMarkPainter();

  static const Color _red = Color(0xFFEA4335);
  static const Color _yellow = Color(0xFFFBBC05);
  static const Color _green = Color(0xFF34A853);
  static const Color _blue = Color(0xFF4285F4);

  static double _rad(double degrees) => degrees * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    // Work in a 24x24 grid, then scale: the proportions below come from the
    // official mark.
    final double k = size.width / 24;
    canvas.save();
    canvas.scale(k);

    const Offset centre = Offset(12, 12);
    const double ring = 8.0; // radius of the stroke centreline
    const double stroke = 4.6;

    final Rect rect = Rect.fromCircle(center: centre, radius: ring);
    final Paint arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    // Angles run clockwise on screen, -90 deg is straight up.
    // Red covers the top, blue the upper right down to the crossbar, green the
    // lower right, yellow the left.
    canvas.drawArc(rect, _rad(190), _rad(95), false, arc..color = _red);
    canvas.drawArc(rect, _rad(288), _rad(72), false, arc..color = _blue);
    canvas.drawArc(rect, _rad(4), _rad(84), false, arc..color = _green);
    canvas.drawArc(rect, _rad(92), _rad(94), false, arc..color = _yellow);

    // The blue crossbar, running from the middle of the mark to the ring.
    final RRect bar = RRect.fromLTRBAndCorners(
      11.4,
      12 - stroke / 2,
      ring + 12 - 0.2,
      12 + stroke / 2,
      topLeft: const Radius.circular(0.8),
      bottomLeft: const Radius.circular(0.8),
    );
    canvas.drawRRect(bar, Paint()..color = _blue);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_GoogleMarkPainter oldDelegate) => false;
}

/// The Telegram roundel: official blue gradient plus the white paper plane.
class TelegramMark extends StatelessWidget {
  const TelegramMark({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: const _TelegramMarkPainter(),
      );
}

class _TelegramMarkPainter extends CustomPainter {
  const _TelegramMarkPainter();

  static const Color _top = Color(0xFF37AEE2);
  static const Color _bottom = Color(0xFF1E96C8);

  @override
  void paint(Canvas canvas, Size size) {
    final double k = size.width / 24;
    canvas.save();
    canvas.scale(k);

    const Rect box = Rect.fromLTWH(0, 0, 24, 24);
    canvas.drawCircle(
      const Offset(12, 12),
      12,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[_top, _bottom],
        ).createShader(box),
    );

    // The plane: body, then the folded wing in a slightly cooler white so the
    // crease reads at small sizes.
    final Path body = Path()
      ..moveTo(20.4, 4.4)
      ..lineTo(3.2, 11.1)
      ..lineTo(9.0, 13.3)
      ..lineTo(10.4, 19.3)
      ..lineTo(13.0, 15.7)
      ..lineTo(17.5, 19.0)
      ..close();
    canvas.drawPath(body, Paint()..color = Colors.white);

    final Path fold = Path()
      ..moveTo(9.0, 13.3)
      ..lineTo(20.4, 4.4)
      ..lineTo(13.0, 15.7)
      ..close();
    canvas.drawPath(fold, Paint()..color = const Color(0xFFD3E8F3));

    canvas.restore();
  }

  @override
  bool shouldRepaint(_TelegramMarkPainter oldDelegate) => false;
}

/// Round glass button that carries one of the marks above.
class SocialSignInButton extends StatelessWidget {
  const SocialSignInButton({
    super.key,
    required this.child,
    required this.onTap,
    this.semanticLabel,
    this.size = 54,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: GlukColors.glass,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(size / 2),
          side: const BorderSide(color: GlukColors.stroke),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
