import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../widgets/dotted_world.dart';
import '../widgets/glass.dart';
import '../widgets/logo.dart';
import 'login_screen.dart';

/// The first screen of the mock-up: a slowly spinning dotted planet, the
/// headline "Access the world with Super Fast VPN Servers..." and a "Let's Go"
/// pill.
///
/// Onboarding and sign-in share one screen on purpose. "Let's Go" does not push
/// a route; it drives a single number ([DottedWorld.globeness] 1 -> 0) so the
/// planet unrolls into the flat world map that the home screen uses as its
/// background, and the login card fades in on top. One widget, one animation,
/// no crossfade between two different pictures of the same globe.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  bool _showLogin = false;

  @override
  void dispose() {
    _morph.dispose();
    super.dispose();
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
          Positioned.fill(child: _Backdrop(morph: _morph, motion: motion)),
          // Keeps the bottom of the map fading out like the mock-up's mask.
          const Positioned.fill(child: IgnorePointer(child: _BottomFade())),
          SafeArea(
            child: AnimatedSwitcher(
              duration: motion.transition(GlukMotion.screen),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: _showLogin
                  ? LoginView(key: const ValueKey<String>('login'), onBack: _backToIntro)
                  : _IntroPanel(
                      key: const ValueKey<String>('intro'),
                      onStart: _openLogin,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Planet -> map. [morph] 0 = planet, 1 = flat map.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.morph, required this.motion});

  final Animation<double> morph;
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
          animation: morph,
          builder: (BuildContext context, Widget? _) {
            final double m = Curves.easeInOutCubic.transform(morph.value);
            return Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Opacity(
                    opacity: (1 - m).clamp(0.0, 1.0),
                    child: Center(child: _Halo(motion: motion)),
                  ),
                ),
                Positioned.fill(
                  child: DottedWorld(
                    globeness: 1 - m,
                    rotationDegrees: spin * 360,
                    // 1.9 makes the sphere about 236 px across on a 390 px
                    // wide phone, matching `.globe` in the mock-up.
                    zoom: lerpDouble(1.9, 1.3, m)!,
                    focus: Offset(0.5, lerpDouble(0.5, 0.36, m)!),
                    dotOpacity: lerpDouble(0.62, 0.45, m)!,
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

/// `.globe-halo` - a 300 px violet-to-blue glow that breathes behind the planet.
class _Halo extends StatelessWidget {
  const _Halo({required this.motion});

  final MotionController motion;

  @override
  Widget build(BuildContext context) {
    return LoopingBuilder(
      duration: GlukMotion.haloPulse,
      reduceMotion: motion.reduceMotion,
      frozenValue: 0.5,
      reverse: true,
      builder: (BuildContext context, double t) => Transform.scale(
        scale: 0.92 + 0.14 * t,
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

/// `.map-stage` mask: the map dissolves into the page background at the bottom
/// so the call to action is never fighting with dots.
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
          stops: <double>[0, 0.52, 0.82, 1],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}

class _IntroPanel extends StatelessWidget {
  const _IntroPanel({super.key, required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const GlukLogo(size: 56),
              const SizedBox(width: 12),
              Text('GlukVPN', style: text.titleMedium),
            ],
          ),
          const SizedBox(height: 22),
          // `.ob-head h1` - 25 px / 700, with the second half in violet.
          RichText(
            text: TextSpan(
              style: text.headlineMedium,
              children: <InlineSpan>[
                const TextSpan(text: 'Access the world with\n'),
                TextSpan(
                  text: 'Super Fast VPN Servers\u2026',
                  style: text.headlineMedium?.copyWith(
                    color: GlukColors.violetLight,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          PrimaryPillButton(label: "Let's Go", onPressed: onStart),
        ],
      ),
    );
  }
}
