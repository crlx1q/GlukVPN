import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../utils/blob.dart';

/// Phases the button can be in. Each one keeps the same motion language and
/// only changes accent, tempo and brightness.
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
/// Three points matter for getting it right:
///
///  * the energy is a pair of **filled** blobs whose eight border radii morph,
///    not a ring of orbiting particles;
///  * the glow is one of the stacked layers **under** the sphere, not a shadow
///    attached to it - which is what makes the button read as sitting inside a
///    field rather than glowing at the edges;
///  * the blob outline is built by [blobPath], not by a rounded rectangle. Two
///    radii along one edge can add up to more than the edge itself, and an
///    `RRect` clamps each corner separately, which used to leave a little
///    cross-shaped spur on the frames where that happened.
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
        return 0.86;
      case ConnectPhase.disconnecting:
        return 0.50;
      case ConnectPhase.connecting:
        return 0.34;
      case ConnectPhase.idle:
        return 0;
    }
  }

  /// ЭТАП 3: три честных цветовых состояния, как в расширении.
  ///
  /// В Chrome это сделано тремя классами на `.hero` (theme.css):
  ///
  /// ```css
  /// /* отключено */  .blob-glow { opacity: 0 }
  ///                 .blob-outer { opacity: .16; filter: grayscale(1) }
  /// /* подключается */ .hero.busy .blob-glow { opacity: .85 }
  ///                 .hero.busy .blob-outer { opacity: .7; filter: none }
  /// /* подключено */  .hero.on .blob-glow { opacity: 1 }
  ///                 .hero.on .blob-outer { background: linear-gradient(150deg, #86f2c6, var(--green-deep)) }
  /// ```
  ///
  /// Раньше во Flutter все три состояния выглядели одинаково
  /// фиолетовыми и отличались только яркостью, поэтому на ПК и
  /// телефоне было непонятно, что именно сейчас происходит.

  /// Прозрачность `.blob-glow`.
  double get _glow {
    switch (widget.phase) {
      case ConnectPhase.connected:
        return 1;
      case ConnectPhase.connecting:
        return 0.85;
      case ConnectPhase.disconnecting:
        return 0.70;
      case ConnectPhase.idle:
        return 0;
    }
  }

  /// Множитель прозрачности `.blob-outer` / `.blob-inner-ring`.
  double get _blobFade {
    switch (widget.phase) {
      case ConnectPhase.connected:
        return 1;
      case ConnectPhase.connecting:
        return 0.74;
      case ConnectPhase.disconnecting:
        return 0.80;
      case ConnectPhase.idle:
        return 0.17;
    }
  }

  /// Сила `filter: grayscale(1)`: в покое шар серый, а не фиолетовый.
  double get _grey => widget.phase == ConnectPhase.idle ? 1 : 0;

  /// Brightness of the field behind the sphere.
  ///
  /// A tunnel that is up earns full power. Sitting disconnected, the same
  /// artwork at full strength shouts for attention it has not earned, so the
  /// resting state is held back a little - dimmer, not grey, and the hue and
  /// motion are untouched.
  double get _energy {
    switch (widget.phase) {
      case ConnectPhase.connected:
        return 1;
      case ConnectPhase.connecting:
        return 0.94;
      case ConnectPhase.disconnecting:
        return 0.86;
      case ConnectPhase.idle:
        return 0.72;
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
    final double dim = _energy * (_enabled ? 1 : 0.55);

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
            dim: dim * _glow,
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
                    frames: morph1,
                    gradient: _tinted(GlukGradients.blobOuter),
                    opacity: 0.95 * dim * _blobFade,
                  ),
                  _MorphBlob(
                    size: GlukSizes.blob * _k,
                    t: t,
                    frames: morph2,
                    gradient: _tinted(GlukGradients.blobInner),
                    opacity: 0.40 * dim * _blobFade,
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

  /// `filter: grayscale(1)` из CSS: светлота остаётся, тон убирается.
  static Color _desaturated(Color c) =>
      HSLColor.fromColor(c).withSaturation(0).toColor();

  LinearGradient _tinted(LinearGradient base) {
    if (_tint == 0 && _grey == 0) return base;
    return LinearGradient(
      begin: base.begin,
      end: base.end,
      colors: base.colors.map((Color c) {
        final Color rest = Color.lerp(c, _desaturated(c), _grey)!;
        return Color.lerp(rest, _accent, _tint)!;
      }).toList(growable: false),
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
          opacity: (ui.lerpDouble(0.6, 1, k)! * dim).clamp(0.0, 1.0),
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
/// each a percentage of the box, plus a `rotate()` and a `scale()`.
class MorphKey {
  const MorphKey({required this.at, required this.shape});

  /// Position in the timeline, 0..1.
  final double at;
  final BlobShape shape;
}

/// `@keyframes morph1` - the opaque blob.
const List<MorphKey> morph1 = <MorphKey>[
  MorphKey(
    at: 0,
    shape: BlobShape(
      h: <double>[0.42, 0.58, 0.65, 0.35],
      v: <double>[0.45, 0.40, 0.60, 0.55],
    ),
  ),
  MorphKey(
    at: 0.33,
    shape: BlobShape(
      h: <double>[0.60, 0.40, 0.45, 0.55],
      v: <double>[0.55, 0.65, 0.35, 0.45],
      rotation: 8,
      scale: 1.02,
    ),
  ),
  MorphKey(
    at: 0.66,
    shape: BlobShape(
      h: <double>[0.48, 0.52, 0.38, 0.62],
      v: <double>[0.40, 0.55, 0.45, 0.60],
      rotation: -6,
      scale: 0.99,
    ),
  ),
  MorphKey(
    at: 1,
    shape: BlobShape(
      h: <double>[0.42, 0.58, 0.65, 0.35],
      v: <double>[0.45, 0.40, 0.60, 0.55],
    ),
  ),
];

/// `@keyframes morph2` - the blurred counter-rotating blob.
const List<MorphKey> morph2 = <MorphKey>[
  MorphKey(
    at: 0,
    shape: BlobShape(
      h: <double>[0.55, 0.45, 0.40, 0.60],
      v: <double>[0.50, 0.45, 0.55, 0.50],
      scale: 1.08,
    ),
  ),
  MorphKey(
    at: 0.5,
    shape: BlobShape(
      h: <double>[0.40, 0.60, 0.55, 0.45],
      v: <double>[0.60, 0.50, 0.50, 0.40],
      rotation: -10,
      scale: 1.14,
    ),
  ),
  MorphKey(
    at: 1,
    shape: BlobShape(
      h: <double>[0.55, 0.45, 0.40, 0.60],
      v: <double>[0.50, 0.45, 0.55, 0.50],
      scale: 1.08,
    ),
  ),
];

/// The shape at a point in the timeline, with `ease-in-out` between keys -
/// exactly what `animation-timing-function` does between two CSS keyframes.
BlobShape morphAt(List<MorphKey> frames, double t) {
  final double clamped = t.clamp(0.0, 1.0);
  int index = 0;
  for (int i = 0; i < frames.length - 1; i++) {
    if (clamped >= frames[i].at) index = i;
  }
  final MorphKey from = frames[index];
  final MorphKey to = frames[math.min(index + 1, frames.length - 1)];
  final double span = (to.at - from.at).abs();
  final double local = span == 0 ? 0 : ((clamped - from.at) / span).clamp(0.0, 1.0);
  return BlobShape.lerp(
    from.shape,
    to.shape,
    Curves.easeInOut.transform(local),
  );
}

/// A filled gradient blob whose outline, rotation and scale follow a CSS
/// keyframe list.
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
  final List<MorphKey> frames;
  final LinearGradient gradient;
  final double opacity;
  final double blur;

  @override
  Widget build(BuildContext context) {
    Widget blob = CustomPaint(
      size: Size(size, size),
      painter: _BlobPainter(
        shape: morphAt(frames, t),
        gradient: gradient,
        opacity: opacity.clamp(0.0, 1.0),
      ),
    );

    if (blur > 0) {
      blob = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: blob,
      );
    }
    return SizedBox(width: size, height: size, child: blob);
  }
}

/// Draws one blob.
///
/// The outline comes from [blobPath], which normalises the eight radii the way
/// CSS does before drawing arcs, so neighbouring segments always meet
/// tangentially. Rotation and scale are canvas transforms about the centre,
/// which keeps the path itself untouched - there is nothing left that can
/// pinch, spike or flash mid-morph.
class _BlobPainter extends CustomPainter {
  const _BlobPainter({
    required this.shape,
    required this.gradient,
    required this.opacity,
  });

  final BlobShape shape;
  final LinearGradient gradient;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || opacity <= 0) return;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(shape.rotation * math.pi / 180);
    canvas.scale(shape.scale);
    canvas.translate(-size.width / 2, -size.height / 2);

    final Rect box = Offset.zero & size;
    // Opacity is folded into the gradient stops rather than applied with a
    // saved layer: one draw call, and no chance of a seam where two layers
    // composite.
    final LinearGradient faded = LinearGradient(
      begin: gradient.begin,
      end: gradient.end,
      colors: gradient.colors
          .map((Color c) => c.withOpacity(c.opacity * opacity))
          .toList(growable: false),
      stops: gradient.stops,
    );

    canvas.drawPath(
      blobPath(size: size, h: shape.h, v: shape.v),
      Paint()
        ..isAntiAlias = true
        ..shader = faded.createShader(box),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BlobPainter old) =>
      old.opacity != opacity ||
      old.shape.rotation != shape.rotation ||
      old.shape.scale != shape.scale ||
      !_sameRadii(old.shape.h, shape.h) ||
      !_sameRadii(old.shape.v, shape.v) ||
      old.gradient != gradient;

  static bool _sameRadii(List<double> a, List<double> b) {
    for (int i = 0; i < 4; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The power symbol, with a spinner around it while a tunnel is being set up or
/// torn down.
///
/// This one loop ignores the reduced-motion setting. Everything decorative in
/// the app holds still on battery saver, but a handshake can take a few
/// seconds, and a frozen arc there does not read as "saving power" - it reads
/// as a hung app. Progress feedback is information, not decoration.
class _Glyph extends StatelessWidget {
  const _Glyph({
    required this.size,
    required this.colour,
    required this.accent,
    required this.busy,
  });

  final double size;
  final Color colour;
  final Color accent;
  final bool busy;

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
            duration: const Duration(milliseconds: 1100),
            reduceMotion: false,
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
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true
      ..shader = SweepGradient(
        colors: <Color>[colour.withOpacity(0), colour.withOpacity(0.6)],
      ).createShader(rect);
    canvas.drawArc(rect.deflate(1), -math.pi / 2, math.pi * 1.45, false, paint);
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.colour != colour;
}
