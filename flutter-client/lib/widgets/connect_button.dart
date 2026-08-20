import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Phases the button can be in. Each one keeps the same motion language and
/// only changes accent and tempo.
enum ConnectPhase { idle, connecting, connected, disconnecting }

/// The connect control from `gluk_vpn_v5_connection.html`, ported layer for
/// layer rather than reinterpreted.
///
/// The original is four stacked elements inside `.blob-zone`:
///
/// ```css
/// .blob-glow       { 260px; radial-gradient(circle, rgba(124,92,246,.35), transparent 65%);
///                    filter: blur(4px); animation: glowPulse 3.6s ease-in-out infinite; }
/// .blob-outer      { 210px; linear-gradient(150deg, violet-light, indigo); opacity:.95;
///                    animation: morph1 7s ease-in-out infinite; }
/// .blob-inner-ring { 210px; linear-gradient(320deg, blue, violet); opacity:.4;
///                    filter: blur(2px); animation: morph2 7s ease-in-out infinite; }
/// .power-btn       { 150px; radial-gradient(circle at 35% 30%, #201a30, #0a0812 75%);
///                    box-shadow: inset 0 0 0 1px rgba(255,255,255,.06),
///                                0 20px 40px rgba(0,0,0,.6);
///                    transition: transform .15s;  &:active { transform: scale(.96) } }
/// ```
///
/// Two points matter for getting it right:
///
///  * the energy is a pair of **filled** blobs whose eight border radii morph,
///    not a ring of orbiting particles, and
///  * the glow is one of the stacked layers **under** the sphere, not a shadow
///    attached to it - which is what makes the button read as sitting inside a
///    field rather than glowing at the edges.
///
/// Everything here is authored at the mock-up's 150 px button and scaled from
/// [size], so the proportions between glow, blobs and sphere never drift.
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

  /// The mock-up is authored at 150 px; everything else is proportional.
  double get _k => widget.size / GlukSizes.powerButton;

  bool get _enabled => widget.onTap != null;

  bool get _busy =>
      widget.phase == ConnectPhase.connecting ||
      widget.phase == ConnectPhase.disconnecting;

  /// One accent per phase. `idle` is the mock-up untouched; the others tint the
  /// same gradients instead of replacing them.
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

  /// How far the blob gradients are pulled towards the accent. Idle stays at
  /// zero so the resting state is exactly the approved artwork.
  double get _tint {
    switch (widget.phase) {
      case ConnectPhase.connected:
        return 0.50;
      case ConnectPhase.disconnecting:
        return 0.34;
      case ConnectPhase.connecting:
        return 0.22;
      case ConnectPhase.idle:
        return 0;
    }
  }

  /// `morph1` / `morph2` run at 7s in the mock-up. Connecting speeds the field
  /// up, a settled tunnel slows it down; the shapes never change.
  Duration get _morphPeriod {
    switch (widget.phase) {
      case ConnectPhase.connecting:
        return const Duration(milliseconds: 3400);
      case ConnectPhase.disconnecting:
        return const Duration(milliseconds: 5000);
      case ConnectPhase.connected:
        return const Duration(milliseconds: 9000);
      case ConnectPhase.idle:
        return GlukMotion.blobMorph;
    }
  }

  @override
  Widget build(BuildContext context) {
    // `.blob-zone` is 260 px across - the glow is the widest layer.
    final double stage = GlukSizes.blobGlow * _k;

    return SizedBox(
      width: stage,
      height: stage,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // --- .blob-glow ------------------------------------------------
          _Glow(
            size: stage,
            colour: Color.lerp(_glowViolet, _accent, _tint)!,
            blur: 4 * _k,
            dim: _enabled ? 1 : 0.45,
            reduceMotion: widget.reduceMotion,
          ),

          // --- .blob-outer / .blob-inner-ring ----------------------------
          LoopingBuilder(
            duration: _morphPeriod,
            reduceMotion: widget.reduceMotion,
            frozenValue: 0.18,
            builder: (BuildContext context, double t) {
              return Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  _MorphBlob(
                    size: GlukSizes.blob * _k,
                    t: t,
                    frames: _morph1,
                    gradient: _tinted(GlukGradients.blobOuter),
                    opacity: 0.95 * (_enabled ? 1 : 0.5),
                  ),
                  _MorphBlob(
                    size: GlukSizes.blob * _k,
                    t: t,
                    frames: _morph2,
                    gradient: _tinted(GlukGradients.blobInner),
                    opacity: 0.40 * (_enabled ? 1 : 0.5),
                    blur: 2 * _k,
                  ),
                ],
              );
            },
          ),

          // --- .power-btn -------------------------------------------------
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
            onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
            onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
            onTap: widget.onTap,
            child: AnimatedScale(
              // `transition: transform .15s ease` + `:active { scale(.96) }`
              scale: _pressed ? 0.96 : 1,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: GlukGradients.powerButton,
                  // `inset 0 0 0 1px rgba(255,255,255,0.06)`
                  border: Border.all(color: Colors.white.withOpacity(0.06)),
                  boxShadow: <BoxShadow>[
                    // `0 20px 40px rgba(0,0,0,0.6)` - depth, not glow.
                    BoxShadow(
                      color: Colors.black.withOpacity(0.6),
                      blurRadius: 40 * _k,
                      offset: Offset(0, 20 * _k),
                    ),
                  ],
                ),
                child: Center(
                  child: _Glyph(
                    size: 40 * _k,
                    colour: widget.phase == ConnectPhase.idle
                        ? GlukColors.powerGlyph
                        : Color.lerp(GlukColors.powerGlyph, _accent, 0.85)!,
                    accent: _accent,
                    busy: _busy,
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

  /// `rgba(124,92,246,0.35)` from `.blob-glow`.
  static const Color _glowViolet = Color(0xFF7C5CF6);

  LinearGradient _tinted(LinearGradient base) {
    if (_tint == 0) return base;
    return LinearGradient(
      begin: base.begin,
      end: base.end,
      colors: base.colors
          .map((Color c) => Color.lerp(c, _accent, _tint)!)
          .toList(growable: false),
    );
  }
}

/// `.blob-glow`: a soft radial field that breathes under everything else.
///
/// `glowPulse` is `opacity .6 -> 1 -> .6` with `scale .94 -> 1.05 -> .94`, so
/// the layer is never fully still and never flashes.
class _Glow extends StatelessWidget {
  const _Glow({
    required this.size,
    required this.colour,
    required this.blur,
    required this.dim,
    required this.reduceMotion,
  });

  final double size;
  final Color colour;
  final double blur;
  final double dim;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    return LoopingBuilder(
      duration: GlukMotion.glowPulse,
      reduceMotion: reduceMotion,
      frozenValue: 0.5,
      builder: (BuildContext context, double t) {
        // A cosine gives the ease-in-out shape of the CSS keyframe for free.
        final double k = 0.5 - 0.5 * math.cos(t * 2 * math.pi);
        return Opacity(
          opacity: ui.lerpDouble(0.6, 1, k)! * dim,
          child: Transform.scale(
            scale: ui.lerpDouble(0.94, 1.05, k)!,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: <Color>[
                      colour.withOpacity(0.35),
                      colour.withOpacity(0),
                    ],
                    stops: const <double>[0, 0.65],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One keyframe of `morph1` / `morph2`.
///
/// CSS writes eight radii as `TL TR BR BL / TL TR BR BL`, horizontal first,
/// each a percentage of the box. Flutter says the same thing with four
/// [Radius.elliptical] corners, so the shape can be reproduced exactly instead
/// of approximated with a sine wave.
class _MorphFrame {
  const _MorphFrame({
    required this.at,
    required this.h,
    required this.v,
    required this.rotation,
    required this.scale,
  });

  /// Position in the timeline, 0..1.
  final double at;

  /// Horizontal radii, in box fractions: TL, TR, BR, BL.
  final List<double> h;

  /// Vertical radii, same order.
  final List<double> v;

  /// Degrees.
  final double rotation;
  final double scale;
}

/// `@keyframes morph1` - the opaque blob.
const List<_MorphFrame> _morph1 = <_MorphFrame>[
  _MorphFrame(
    at: 0,
    h: <double>[0.42, 0.58, 0.65, 0.35],
    v: <double>[0.45, 0.40, 0.60, 0.55],
    rotation: 0,
    scale: 1,
  ),
  _MorphFrame(
    at: 0.33,
    h: <double>[0.60, 0.40, 0.45, 0.55],
    v: <double>[0.55, 0.65, 0.35, 0.45],
    rotation: 8,
    scale: 1.02,
  ),
  _MorphFrame(
    at: 0.66,
    h: <double>[0.48, 0.52, 0.38, 0.62],
    v: <double>[0.40, 0.55, 0.45, 0.60],
    rotation: -6,
    scale: 0.99,
  ),
  _MorphFrame(
    at: 1,
    h: <double>[0.42, 0.58, 0.65, 0.35],
    v: <double>[0.45, 0.40, 0.60, 0.55],
    rotation: 0,
    scale: 1,
  ),
];

/// `@keyframes morph2` - the blurred counter-rotating blob.
const List<_MorphFrame> _morph2 = <_MorphFrame>[
  _MorphFrame(
    at: 0,
    h: <double>[0.55, 0.45, 0.40, 0.60],
    v: <double>[0.50, 0.45, 0.55, 0.50],
    rotation: 0,
    scale: 1.08,
  ),
  _MorphFrame(
    at: 0.5,
    h: <double>[0.40, 0.60, 0.55, 0.45],
    v: <double>[0.60, 0.50, 0.50, 0.40],
    rotation: -10,
    scale: 1.14,
  ),
  _MorphFrame(
    at: 1,
    h: <double>[0.55, 0.45, 0.40, 0.60],
    v: <double>[0.50, 0.45, 0.55, 0.50],
    rotation: 0,
    scale: 1.08,
  ),
];

/// A filled gradient blob whose corner radii, rotation and scale follow a CSS
/// keyframe list. `ease-in-out` is applied between each pair of stops, exactly
/// like `animation-timing-function` does.
class _MorphBlob extends StatelessWidget {
  const _MorphBlob({
    required this.size,
    required this.t,
    required this.frames,
    required this.gradient,
    required this.opacity,
    this.blur = 0,
  });

  final double size;

  /// 0..1 through the keyframe list.
  final double t;
  final List<_MorphFrame> frames;
  final LinearGradient gradient;
  final double opacity;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final double clamped = t.clamp(0.0, 1.0);
    int index = 0;
    for (int i = 0; i < frames.length - 1; i++) {
      if (clamped >= frames[i].at) index = i;
    }
    final _MorphFrame from = frames[index];
    final _MorphFrame to = frames[math.min(index + 1, frames.length - 1)];
    final double span = (to.at - from.at).abs();
    final double local =
        span == 0 ? 0 : ((clamped - from.at) / span).clamp(0.0, 1.0);
    final double eased = Curves.easeInOut.transform(local);

    double radius(int corner, bool horizontal) {
      final double a = horizontal ? from.h[corner] : from.v[corner];
      final double b = horizontal ? to.h[corner] : to.v[corner];
      return ui.lerpDouble(a, b, eased)! * size;
    }

    Widget blob = Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Transform.rotate(
        angle: ui.lerpDouble(from.rotation, to.rotation, eased)! *
            math.pi /
            180,
        child: Transform.scale(
          scale: ui.lerpDouble(from.scale, to.scale, eased)!,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              gradient: gradient,
              borderRadius: BorderRadius.only(
                topLeft: Radius.elliptical(radius(0, true), radius(0, false)),
                topRight: Radius.elliptical(radius(1, true), radius(1, false)),
                bottomRight:
                    Radius.elliptical(radius(2, true), radius(2, false)),
                bottomLeft:
                    Radius.elliptical(radius(3, true), radius(3, false)),
              ),
            ),
          ),
        ),
      ),
    );

    if (blur > 0) {
      blob = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: blob,
      );
    }
    return blob;
  }
}

/// The power symbol. While a tunnel is being set up or torn down a hairline
/// sweep runs just inside the sphere's edge, so a slow handshake never looks
/// frozen - one thin arc, no spinner furniture.
class _Glyph extends StatelessWidget {
  const _Glyph({
    required this.size,
    required this.colour,
    required this.accent,
    required this.busy,
    required this.reduceMotion,
  });

  final double size;
  final Color colour;
  final Color accent;
  final bool busy;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final Widget glyph = Icon(
      Icons.power_settings_new_rounded,
      size: size,
      color: colour,
    );
    if (!busy) return glyph;

    final double ring = size * 2.2;
    return SizedBox(
      width: ring,
      height: ring,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          LoopingBuilder(
            duration: const Duration(milliseconds: 1600),
            reduceMotion: reduceMotion,
            frozenValue: 0.25,
            builder: (BuildContext context, double t) => Transform.rotate(
              angle: t * 2 * math.pi,
              child: CustomPaint(
                size: Size(ring, ring),
                painter: _SweepPainter(colour: accent),
              ),
            ),
          ),
          glyph,
        ],
      ),
    );
  }
}

class _SweepPainter extends CustomPainter {
  const _SweepPainter({required this.colour});

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true
      ..shader = SweepGradient(
        colors: <Color>[colour.withOpacity(0), colour.withOpacity(0.55)],
      ).createShader(rect);
    canvas.drawArc(rect.deflate(1), -math.pi / 2, math.pi * 1.25, false, paint);
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.colour != colour;
}
