import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../widgets/dotted_world.dart';
import '../widgets/glass.dart';
import '../widgets/logo.dart';
import 'login_screen.dart';

/// Three intro screens, then sign-in - all on one continuous stage.
///
/// The planet is never re-created: a single [DottedWorld] lives behind
/// everything, and one number drives it. Swiping moves the camera (zoom +
/// focus) across three framings; "Let's Go" keeps going and unrolls the sphere
/// into the flat world map that the home screen uses as its background
/// ([DottedWorld.globeness] 1 -> 0). Nothing crossfades between two pictures of
/// the same globe, which is what makes it feel like one place rather than three
/// slides.
///
/// Page content is not a stock PageView slide either: each panel is driven by
/// its own distance from the viewport centre, so headlines drift, fade and
/// scale at slightly different rates.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  static const int _pages = 3;

  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  final PageController _controller = PageController();

  /// Fractional page offset, 0..2. Drives every parallax on this screen.
  final ValueNotifier<double> _page = ValueNotifier<double>(0);

  bool _showLogin = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncPage);
  }

  void _syncPage() {
    final double? value = _controller.page;
    if (value != null) _page.value = value;
  }

  @override
  void dispose() {
    _controller.removeListener(_syncPage);
    _controller.dispose();
    _page.dispose();
    _morph.dispose();
    super.dispose();
  }

  void _next() {
    final int current = _page.value.round();
    if (current >= _pages - 1) {
      _openLogin();
      return;
    }
    _controller.animateToPage(
      current + 1,
      duration: context
          .read<MotionController>()
          .transition(const Duration(milliseconds: 620)),
      curve: Curves.easeOutCubic,
    );
  }

  void _openLogin() {
    if (_showLogin) return;
    _morph.duration = context
        .read<MotionController>()
        .transition(const Duration(milliseconds: 900));
    setState(() => _showLogin = true);
    _morph.forward();
  }

  void _backToIntro() {
    if (!_showLogin) return;
    setState(() => _showLogin = false);
    _morph.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final MotionController motion = context.watch<MotionController>();

    return Scaffold(
      backgroundColor: GlukColors.pageBg,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: _Backdrop(morph: _morph, page: _page, motion: motion),
          ),
          // Keeps the bottom of the stage fading out like the mock-up's mask.
          const Positioned.fill(child: IgnorePointer(child: _BottomFade())),
          SafeArea(
            child: AnimatedSwitcher(
              duration: motion.transition(GlukMotion.screen),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: _showLogin
                  ? LoginView(
                      key: const ValueKey<String>('login'),
                      onBack: _backToIntro,
                    )
                  : _IntroPager(
                      key: const ValueKey<String>('intro'),
                      controller: _controller,
                      page: _page,
                      pages: _pages,
                      onNext: _next,
                      onSkip: _openLogin,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The three framings the camera moves between, plus the final flat map.
class _Framing {
  const _Framing({
    required this.zoom,
    required this.focus,
    required this.dotOpacity,
  });

  final double zoom;
  final Offset focus;
  final double dotOpacity;

  static _Framing lerp(_Framing a, _Framing b, double t) => _Framing(
        zoom: lerpDouble(a.zoom, b.zoom, t)!,
        focus: Offset.lerp(a.focus, b.focus, t)!,
        dotOpacity: lerpDouble(a.dotOpacity, b.dotOpacity, t)!,
      );
}

const List<_Framing> _framings = <_Framing>[
  // 1. Global access: the whole planet, centred, calm.
  _Framing(zoom: 1.9, focus: Offset(0.5, 0.46), dotOpacity: 0.62),
  // 2. Privacy: closer and off to one side, so the copy has room.
  _Framing(zoom: 2.5, focus: Offset(0.34, 0.34), dotOpacity: 0.70),
  // 3. Speed: large and high, the framing the home screen inherits.
  _Framing(zoom: 3.0, focus: Offset(0.52, 0.24), dotOpacity: 0.78),
];

/// Planet -> map, plus the camera move across the three pages.
class _Backdrop extends StatelessWidget {
  const _Backdrop({
    required this.morph,
    required this.page,
    required this.motion,
  });

  final Animation<double> morph;
  final ValueNotifier<double> page;
  final MotionController motion;

  @override
  Widget build(BuildContext context) {
    return LoopingBuilder(
      duration: GlukMotion.globeSpin,
      reduceMotion: motion.reduceMotion,
      // A frozen planet still shows Europe/Africa rather than the empty Pacific.
      frozenValue: 0.17,
      builder: (BuildContext context, double spin) {
        return AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[morph, page]),
          builder: (BuildContext context, Widget? _) {
            final double m = Curves.easeInOutCubic.transform(morph.value);
            final double p = page.value.clamp(0.0, (_framings.length - 1).toDouble());
            final int index = p.floor();
            final _Framing framing = index >= _framings.length - 1
                ? _framings.last
                : _Framing.lerp(
                    _framings[index],
                    _framings[index + 1],
                    Curves.easeInOut.transform(p - index),
                  );

            // Signing in pulls the camera back out as the sphere flattens.
            final double zoom = lerpDouble(framing.zoom, 1.3, m)!;
            final Offset focus = Offset.lerp(
              framing.focus,
              const Offset(0.5, 0.36),
              m,
            )!;

            return Stack(
              children: <Widget>[
                // A slow violet aurora that drifts against the swipe, so the
                // background is never static.
                Positioned.fill(
                  child: IgnorePointer(
                    child: _Aurora(page: p, motion: motion),
                  ),
                ),
                Positioned.fill(
                  child: Opacity(
                    opacity: (1 - m).clamp(0.0, 1.0),
                    child: Align(
                      alignment: Alignment(
                        (focus.dx - 0.5) * -2,
                        (focus.dy - 0.5) * 2,
                      ),
                      child: _Halo(motion: motion, scale: 0.9 + 0.25 * p),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: DottedWorld(
                    globeness: 1 - m,
                    rotationDegrees: spin * 360,
                    zoom: zoom,
                    focus: focus,
                    dotOpacity: lerpDouble(framing.dotOpacity, 0.45, m)!,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Two soft violet/blue lobes drifting behind the planet.
class _Aurora extends StatelessWidget {
  const _Aurora({required this.page, required this.motion});

  final double page;
  final MotionController motion;

  @override
  Widget build(BuildContext context) {
    return LoopingBuilder(
      duration: GlukMotion.blobMorph,
      reduceMotion: motion.reduceMotion,
      frozenValue: 0.3,
      builder: (BuildContext context, double t) {
        final double drift = math.sin(t * 2 * math.pi);
        return Stack(
          children: <Widget>[
            Positioned(
              left: -120 + page * -40 + drift * 14,
              top: 40 + page * -30,
              child: _blob(GlukColors.violet.withOpacity(0.20), 320),
            ),
            Positioned(
              right: -140 + page * 30 - drift * 18,
              top: 220 + page * 40,
              child: _blob(GlukColors.blue.withOpacity(0.14), 280),
            ),
          ],
        );
      },
    );
  }

  Widget _blob(Color color, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: <Color>[color, color.withOpacity(0)],
          ),
        ),
      );
}

/// `.globe-halo` - a violet-to-blue glow that breathes behind the planet.
class _Halo extends StatelessWidget {
  const _Halo({required this.motion, this.scale = 1});

  final MotionController motion;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return LoopingBuilder(
      duration: GlukMotion.haloPulse,
      reduceMotion: motion.reduceMotion,
      frozenValue: 0.5,
      reverse: true,
      builder: (BuildContext context, double t) => Transform.scale(
        scale: (0.92 + 0.14 * t) * scale,
        child: Opacity(
          opacity: 0.62 + 0.38 * t,
          child: Container(
            width: GlukSizes.globeHalo,
            height: GlukSizes.globeHalo,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: GlukGradients.globeHalo,
            ),
          ),
        ),
      ),
    );
  }
}

/// The stage mask: content never fights with dots.
class _BottomFade extends StatelessWidget {
  const _BottomFade();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color(0x00000000),
            Color(0x00000000),
            Color(0xCC05040A),
            Color(0xFF05040A),
          ],
          stops: <double>[0, 0.42, 0.74, 1],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}

class _IntroPager extends StatelessWidget {
  const _IntroPager({
    super.key,
    required this.controller,
    required this.page,
    required this.pages,
    required this.onNext,
    required this.onSkip,
  });

  final PageController controller;
  final ValueNotifier<double> page;
  final int pages;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 16, 0),
          child: Row(
            children: <Widget>[
              const GlukLogo(size: 44),
              const SizedBox(width: 12),
              Text('GlukVPN', style: text.titleMedium),
              const Spacer(),
              ValueListenableBuilder<double>(
                valueListenable: page,
                builder: (BuildContext context, double value, Widget? _) {
                  // Skip disappears on the last page, where the primary action
                  // already is "Let's Go".
                  return AnimatedOpacity(
                    opacity: value > pages - 1.35 ? 0 : 1,
                    duration: const Duration(milliseconds: 200),
                    child: TextButton(
                      onPressed: value > pages - 1.35 ? null : onSkip,
                      child: const Text('Skip'),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: PageView.builder(
            controller: controller,
            itemCount: pages,
            physics: const BouncingScrollPhysics(),
            itemBuilder: (BuildContext context, int index) {
              return ValueListenableBuilder<double>(
                valueListenable: page,
                builder: (BuildContext context, double value, Widget? _) {
                  return _Panel(delta: index - value, index: index);
                },
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 30),
          child: Column(
            children: <Widget>[
              ValueListenableBuilder<double>(
                valueListenable: page,
                builder: (BuildContext context, double value, Widget? _) {
                  return _Progress(value: value, count: pages);
                },
              ),
              const SizedBox(height: 20),
              ValueListenableBuilder<double>(
                valueListenable: page,
                builder: (BuildContext context, double value, Widget? _) {
                  final bool last = value > pages - 1.5;
                  return PrimaryPillButton(
                    label: last ? "Let's Go" : 'Next',
                    onPressed: onNext,
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One intro panel. [delta] is its distance from the centre of the viewport:
/// 0 = centred, -1 = one page to the left, 1 = one page to the right.
class _Panel extends StatelessWidget {
  const _Panel({required this.delta, required this.index});

  final double delta;
  final int index;

  static const List<List<String>> _copy = <List<String>>[
    <String>[
      'Global access',
      'Access the world with',
      'Super Fast VPN Servers\u2026',
      'Reach any of our locations in a tap and browse as if you were there.',
    ],
    <String>[
      'Private by design',
      'Your connection,',
      'yours alone',
      'Modern WireGuard encryption, keys that never leave your phone, and no '
          'record of the sites you visit.',
    ],
    <String>[
      'Built for speed',
      'One tap and',
      "you're through",
      'Fast handshakes and steady tunnels, so streaming and calls keep up with '
          'you.',
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final List<String> copy = _copy[index];
    final double d = delta.clamp(-1.5, 1.5);
    final double away = d.abs().clamp(0.0, 1.0);

    // Each element leaves at its own pace - the eyebrow first, the body last -
    // which is what separates this from a plain sliding page.
    Widget layer(Widget child, double depth) {
      return Transform.translate(
        offset: Offset(d * 90 * depth, away * 18 * depth),
        child: Opacity(
          opacity: (1 - away * 1.25).clamp(0.0, 1.0),
          child: child,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          layer(
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: GlukColors.violet.withOpacity(0.14),
                border: Border.all(color: GlukColors.violet.withOpacity(0.40)),
              ),
              child: Text(
                copy[0].toUpperCase(),
                style: text.labelSmall?.copyWith(
                  color: GlukColors.violetLight,
                  letterSpacing: 1.1,
                ),
              ),
            ),
            0.55,
          ),
          const SizedBox(height: 18),
          layer(
            RichText(
              text: TextSpan(
                style: text.headlineMedium,
                children: <InlineSpan>[
                  TextSpan(text: '${copy[1]}\n'),
                  TextSpan(
                    text: copy[2],
                    style: text.headlineMedium?.copyWith(
                      color: GlukColors.violetLight,
                    ),
                  ),
                ],
              ),
            ),
            1.0,
          ),
          const SizedBox(height: 14),
          layer(
            Text(copy[3], style: text.bodyMedium),
            1.45,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Three pills; the active one stretches instead of just changing colour.
class _Progress extends StatelessWidget {
  const _Progress({required this.value, required this.count});

  final double value;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List<Widget>.generate(count, (int index) {
        final double proximity = (1 - (value - index).abs()).clamp(0.0, 1.0);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Container(
            width: lerpDouble(7, 26, proximity),
            height: 7,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: Color.lerp(
                GlukColors.stroke,
                GlukColors.violetLight,
                proximity,
              ),
            ),
          ),
        );
      }),
    );
  }
}
