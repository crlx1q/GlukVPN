import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Phases the button can be in. Each one has its own motion, not just its own
/// colour: the mock-up's whole point is that the button feels alive.
enum ConnectPhase { idle, connecting, connected, disconnecting }

/// The power button from the mock-up, ported to Flutter.
///
/// Layer for layer, this is `gluk_vpn_v5_connection.html`:
///   `.blob-glow`        260 px radial violet glow, `glowPulse 3.6s`
///   `.blob-outer`       210 px morphing ring, `morph1 7s`
///   `.blob-inner-ring`  210 px counter-morphing ring, `morph2 7s`
///   orbiting particles  the light threads that made the original feel alive
///   `.power-btn`        150 px sphere, `radial-gradient(at 35% 30%, ...)`
///   `:active`           scale(.96)
///
/// The effect *under* the button is the point, so it is drawn as one painter
/// below the sphere rather than as a box-shadow on it.
class GlukConnectButton extends StatefulWidget {
  const GlukConnectButton({
    super.key,
    required this.phase,
    required this.onTap,
    this.reduceMotion = false,
    this.size = GlukSizes.powerButton,
  });

  final ConnectPhase phase;

  /// Null disables the button (offline, no node, no subscription).
  final VoidCallback? onTap;
  final bool reduceMotion;
  final double size;

  @override
  State<GlukConnectButton> createState() => _GlukConnectButtonState();
}

class _GlukConnectButtonState extends State<GlukConnectButton> {
  bool _pressed = false;

  /// One accent per phase. Connected leans green, but the violet body and the
  /// orbital threads stay: a flat green glow is exactly what we are replacing.
  Color get _accent {
    switch (widget.phase) {
      case ConnectPhase.connected:
        return GlukColors.connected;
      case ConnectPhase.connecting:
        return GlukColors.violetLight;
      case ConnectPhase.disconnecting:
        return GlukColors.amber;
      case ConnectPhase.idle:
        return GlukColors.violet;
    }
  }

  /// Orbit speed. Connecting spins up, disconnecting winds down, connected
  /// breathes slowly, idle drifts.
  Duration get _orbitPeriod {
    switch (widget.phase) {
      case ConnectPhase.connecting:
        return const Duration(milliseconds: 2600);
      case ConnectPhase.disconnecting:
        return const Duration(milliseconds: 5200);
      case ConnectPhase.connected:
        return const Duration(milliseconds: 9000);
      case ConnectPhase.idle:
        return const Duration(milliseconds: 7000);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null;
    final double stage = widget.size * (GlukSizes.blobGlow / GlukSizes.powerButton);

    return SizedBox(
      width: stage,
      height: stage,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // --- everything under the sphere -------------------------------
          LoopingBuilder(
            duration: _orbitPeriod,
            reduceMotion: widget.reduceMotion,
            frozenValue: 0.18,
            builder: (BuildContext context, double t) {
              return LoopingBuilder(
                duration: GlukMotion.glowPulse,
                reduceMotion: widget.reduceMotion,
                frozenValue: 0.5,
                builder: (BuildContext context, double pulse) {
                  return CustomPaint(
                    size: Size(stage, stage),
                    painter: _OrbitalFieldPainter(
                      orbit: t,
                      pulse: pulse,
                      accent: _accent,
                      phase: widget.phase,
                      buttonRadius: widget.size / 2,
                      dimmed: !enabled,
                    ),
                  );
                },
              );
            },
          ),

          // --- the sphere itself ------------------------------------------
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
            onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
            onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
            onTap: widget.onTap,
            child: AnimatedScale(
              // `.power-btn:active { transform: scale(.96) }`
              scale: _pressed ? 0.96 : 1,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 320),
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: GlukGradients.powerButton,
                  border: Border.all(
                    color: _accent.withOpacity(enabled ? 0.34 : 0.14),
                    width: 1.2,
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: _accent.withOpacity(enabled ? 0.22 : 0.06),
                      blurRadius: 34,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Center(
                  child: _PowerGlyph(
                    size: widget.size * 0.27,
                    color: widget.phase == ConnectPhase.idle
                        ? GlukColors.powerGlyph
                        : _accent,
                    busy: widget.phase == ConnectPhase.connecting ||
                        widget.phase == ConnectPhase.disconnecting,
                    reduceMotion: widget.reduceMotion,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The power symbol, with a thin sweep while a tunnel is being set up or torn
/// down so the wait never looks frozen.
class _PowerGlyph extends StatelessWidget {
  const _PowerGlyph({
    required this.size,
    required this.color,
    required this.busy,
    required this.reduceMotion,
  });

  final double size;
  final Color color;
  final bool busy;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final Widget glyph = Icon(
      Icons.power_settings_new_rounded,
      size: size,
      color: color,
    );
    if (!busy) return glyph;
    return SizedBox(
      width: size * 1.9,
      height: size * 1.9,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          LoopingBuilder(
            duration: const Duration(milliseconds: 1400),
            reduceMotion: reduceMotion,
            frozenValue: 0.25,
            builder: (BuildContext context, double t) {
              return Transform.rotate(
                angle: t * 2 * math.pi,
                child: CustomPaint(
                  size: Size(size * 1.9, size * 1.9),
                  painter: _SweepPainter(color: color),
                ),
              );
            },
          ),
          glyph,
        ],
      ),
    );
  }
}

class _SweepPainter extends CustomPainter {
  const _SweepPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: <Color>[color.withOpacity(0), color.withOpacity(0.85)],
      ).createShader(rect);
    canvas.drawArc(rect.deflate(1), -math.pi / 2, math.pi * 1.35, false, paint);
  }

  @override
  bool shouldRepaint(_SweepPainter oldDelegate) => oldDelegate.color != color;
}

/// Glow + two morphing rings + orbiting particles, all below the sphere.
class _OrbitalFieldPainter extends CustomPainter {
  const _OrbitalFieldPainter({
    required this.orbit,
    required this.pulse,
    required this.accent,
    required this.phase,
    required this.buttonRadius,
    required this.dimmed,
  });

  /// 0..1 orbit progress.
  final double orbit;

  /// 0..1 glow breath.
  final double pulse;
  final Color accent;
  final ConnectPhase phase;
  final double buttonRadius;
  final bool dimmed;

  static const int _particles = 7;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset centre = Offset(size.width / 2, size.height / 2);
    final double maxRadius = size.width / 2;
    // `glowPulse`: 0.55 -> 1 -> 0.55 over the cycle.
    final double breath = 0.55 + 0.45 * (0.5 - 0.5 * math.cos(pulse * 2 * math.pi));
    final double intensity = dimmed ? 0.35 : 1;

    // --- .blob-glow ------------------------------------------------------
    final Paint glow = Paint()
      ..shader = RadialGradient(
        colors: <Color>[
          accent.withOpacity(0.30 * breath * intensity),
          accent.withOpacity(0.10 * breath * intensity),
          accent.withOpacity(0),
        ],
        stops: const <double>[0, 0.45, 1],
      ).createShader(Rect.fromCircle(center: centre, radius: maxRadius));
    canvas.drawCircle(centre, maxRadius, glow);

    // --- .blob-outer / .blob-inner-ring ----------------------------------
    // Two counter-rotating morphing rings. The radius is modulated by two sine
    // waves, which is what CSS border-radius morphing looks like once traced.
    final double blobRadius = maxRadius * (GlukSizes.blob / GlukSizes.blobGlow);
    _drawMorphRing(
      canvas,
      centre,
      blobRadius,
      phaseShift: orbit * 2 * math.pi,
      lobes: 3,
      amplitude: 0.055,
      paint: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = accent.withOpacity(0.30 * intensity),
    );
    _drawMorphRing(
      canvas,
      centre,
      blobRadius * 0.88,
      phaseShift: -orbit * 2 * math.pi + math.pi / 3,
      lobes: 4,
      amplitude: 0.042,
      paint: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..color = GlukColors.blue.withOpacity(0.22 * intensity),
    );

    // --- orbiting particles ----------------------------------------------
    // An ellipse rather than a circle, tilted, so the ring reads as an orbit
    // around a sphere instead of a flat halo.
    final double orbitRx = buttonRadius * 1.34;
    final double orbitRy = buttonRadius * 0.52;
    const double tilt = -0.38;

    for (int i = 0; i < _particles; i++) {
      final double t = (orbit + i / _particles) % 1;
      final double angle = t * 2 * math.pi;
      final Offset raw = Offset(
        math.cos(angle) * orbitRx,
        math.sin(angle) * orbitRy,
      );
      final Offset point = centre +
          Offset(
            raw.dx * math.cos(tilt) - raw.dy * math.sin(tilt),
            raw.dx * math.sin(tilt) + raw.dy * math.cos(tilt),
          );

      // Particles behind the sphere fade out, which is what sells the depth.
      final double front = 0.5 + 0.5 * math.sin(angle);
      final double opacity = (0.18 + 0.62 * front) * intensity;
      final double radius = 1.1 + 1.5 * front;

      canvas.drawCircle(
        point,
        radius * 3.2,
        Paint()..color = accent.withOpacity(opacity * 0.18),
      );
      canvas.drawCircle(
        point,
        radius,
        Paint()..color = Color.lerp(Colors.white, accent, 0.35)!.withOpacity(opacity),
      );

      // A short light thread trailing each particle: the "живые нити" bit.
      final double trail = angle - 0.42;
      final Offset rawTail = Offset(
        math.cos(trail) * orbitRx,
        math.sin(trail) * orbitRy,
      );
      final Offset tail = centre +
          Offset(
            rawTail.dx * math.cos(tilt) - rawTail.dy * math.sin(tilt),
            rawTail.dx * math.sin(tilt) + rawTail.dy * math.cos(tilt),
          );
      canvas.drawLine(
        tail,
        point,
        Paint()
          ..strokeWidth = 0.9
          ..strokeCap = StrokeCap.round
          ..color = accent.withOpacity(opacity * 0.45),
      );
    }
  }

  void _drawMorphRing(
    Canvas canvas,
    Offset centre,
    double radius, {
    required double phaseShift,
    required int lobes,
    required double amplitude,
    required Paint paint,
  }) {
    final Path path = Path();
    const int steps = 96;
    for (int i = 0; i <= steps; i++) {
      final double a = i / steps * 2 * math.pi;
      final double r = radius *
          (1 + amplitude * math.sin(a * lobes + phaseShift) +
              amplitude * 0.6 * math.sin(a * (lobes + 2) - phaseShift));
      final Offset p = centre + Offset(math.cos(a) * r, math.sin(a) * r);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_OrbitalFieldPainter oldDelegate) =>
      oldDelegate.orbit != orbit ||
      oldDelegate.pulse != pulse ||
      oldDelegate.accent != accent ||
      oldDelegate.phase != phase ||
      oldDelegate.dimmed != dimmed;
}
