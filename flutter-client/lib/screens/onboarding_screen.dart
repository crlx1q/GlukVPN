import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/vpn_controller.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../utils/geo.dart';
import '../utils/map_view.dart';
import '../widgets/dotted_world.dart';
import '../widgets/glass.dart';
import '../widgets/logo.dart';
import '../widgets/page_background.dart';
import 'login_screen.dart';

/// One frame of the onboarding camera.
///
/// A frame is a camera position, not a picture: which meridian and parallel it
/// looks at, how close it is, and where the planet sits on the canvas. Moving
/// between two frames is therefore a flight over one world rather than a
/// crossfade between two hero images.
@immutable
class IntroFrame {
  const IntroFrame({
    required this.longitude,
    required this.latitude,
    required this.zoom,
    required this.anchor,
    required this.dotOpacity,
  });

  /// Degrees; the meridian that ends up in the middle of the sphere.
  final double longitude;

  /// Degrees; the parallel the camera is tilted to.
  final double latitude;

  /// 1 fits the whole map width across the widget, so the sphere's diameter is
  /// `width * zoom / pi`.
  final double zoom;

  /// Where the middle of the planet sits on screen, in 0..1 fractions.
  final Offset anchor;

  final double dotOpacity;

  /// Longitudes take the short way round, so a flight from +170 to -170 crosses
  /// the date line instead of travelling the long way across the Atlantic.
  static double lerpLongitude(double a, double b, double t) {
    final double delta = ((b - a + 540) % 360) - 180;
    return a + delta * t;
  }

  static IntroFrame lerp(IntroFrame a, IntroFrame b, double t) => IntroFrame(
        longitude: lerpLongitude(a.longitude, b.longitude, t),
        latitude: lerpDouble(a.latitude, b.latitude, t)!,
        zoom: lerpDouble(a.zoom, b.zoom, t)!,
        anchor: Offset.lerp(a.anchor, b.anchor, t)!,
        dotOpacity: lerpDouble(a.dotOpacity, b.dotOpacity, t)!,
      );
}

/// The three-beat camera move behind onboarding:
///
///  1. the whole planet, small, a little below the middle of the screen;
///  2. a flight to the user's approximate position, where their marker appears;
///  3. a flight on to the VPN node, ending so close that the planet no longer
///     fits - its left side runs off the screen and only the right half is
///     visible, with a light thread joining the two points.
///
/// Kept as plain data so the whole choreography can be unit-tested without
/// pumping a widget.
class IntroCamera {
  const IntroCamera({required this.self, required this.server});

  /// The user's approximate position (locale/timezone, never GPS).
  final MapPoint self;

  /// The node the app would connect to.
  final MapPoint server;

  static double longitudeOf(MapPoint point) => point.x / mapWidth * 360 - 180;

  static double latitudeOf(MapPoint point) => 90 - point.y / mapHeight * 180;

  List<IntroFrame> get frames {
    final double selfLon = longitudeOf(self);
    final double selfLat = latitudeOf(self);
    final double serverLon = longitudeOf(server);
    final double serverLat = latitudeOf(server);

    return <IntroFrame>[
      // Calm establishing shot: the user's hemisphere, but far enough out that
      // the whole globe is on screen with air around it.
      IntroFrame(
        longitude: IntroFrame.lerpLongitude(selfLon, serverLon, 0.5) - 8,
        latitude: 14,
        zoom: 1.30,
        anchor: const Offset(0.5, 0.53),
        dotOpacity: 0.55,
      ),
      // "This is where I am": the camera arrives over the user's own place.
      IntroFrame(
        longitude: selfLon,
        latitude: selfLat,
        zoom: 2.60,
        anchor: const Offset(0.52, 0.40),
        dotOpacity: 0.72,
      ),
      // The route: framed on the node, but biased east and left on the canvas
      // so both markers stay on screen while the planet overflows it.
      IntroFrame(
        longitude: serverLon + 15,
        latitude: serverLat + 5,
        zoom: 4.40,
        anchor: const Offset(0.30, 0.44),
        dotOpacity: 0.80,
      ),
    ];
  }

  /// The camera at a fractional page position.
  ///
  /// Between two frames the distance dips slightly at the midpoint: a camera
  /// that pulls back a little as it travels and settles in at the end reads as
  /// flight, while a straight interpolation of zoom reads as a zoom ramp - the
  /// exact thing this replaces.
  IntroFrame at(double page) {
    final List<IntroFrame> list = frames;
    final double clamped = page.clamp(0.0, (list.length - 1).toDouble());
    final int index = clamped.floor().clamp(0, list.length - 2);
    final double local = (clamped - index).clamp(0.0, 1.0);
    final double eased = Curves.easeInOutCubic.transform(local);

    final IntroFrame frame = IntroFrame.lerp(list[index], list[index + 1], eased);
    final double dip = math.sin(local * math.pi);
    return IntroFrame(
      longitude: frame.longitude,
      latitude: frame.latitude,
      zoom: frame.zoom * (1 - 0.20 * dip),
      anchor: frame.anchor,
      dotOpacity: frame.dotOpacity,
    );
  }

  /// How visible the user's marker is at a given page position.
  double selfOpacity(double page) => ((page - 0.42) / 0.38).clamp(0.0, 1.0);

  /// How visible the node's marker is.
  double serverOpacity(double page) => ((page - 1.42) / 0.38).clamp(0.0, 1.0);

  /// How much of the user -> node thread is drawn.
  double routeProgress(double page) => ((page - 1.62) / 0.34).clamp(0.0, 1.0);
}

/// Three intro beats and then sign-in, all on one continuous stage.
///
/// A single [DottedWorld] lives behind everything and is never rebuilt from
/// scratch: swiping moves the camera across [IntroCamera]'s frames, and
/// "Let's Go" keeps going - the sphere unrolls into the flat world map
/// ([DottedWorld.globeness] 1 -> 0) which then fills the screen behind the
/// sign-in form. Nothing crossfades between two pictures of the same planet.
///
/// The page view exists only to read swipes; every visual is driven by the
/// fractional page offset, so headlines drift, fade and settle at their own
/// rates instead of sliding as one flat sheet.
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

  /// Fractional page offset, 0..2. Drives the camera and every parallax here.
  final ValueNotifier<double> _page = ValueNotifier<double>(0);

  /// Approximate, from the device locale or its UTC offset. No GPS, no
  /// permission prompt, no geolocation request.
  late final SelfLocation _self = approximateSelfLocation();

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
          .transition(const Duration(milliseconds: 720)),
      curve: Curves.easeInOutCubic,
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

  /// The node the story flies to. Real fleet data when we have it, the shipped
  /// German node's city otherwise - onboarding runs before sign-in, so the
  /// list is usually still empty.
  MapPoint _serverPoint(VpnController vpn) {
    final VpnNodeInfo? node = vpn.selectedNode ??
        (vpn.nodes.isNotEmpty ? vpn.nodes.first : null);
    return (node == null ? null : countryPoint(node.countryCode)) ??
        projectLatLon(50.11, 8.68);
  }

  @override
  Widget build(BuildContext context) {
    final MotionController motion = context.watch<MotionController>();
    final VpnController vpn = context.watch<VpnController>();
    final IntroCamera camera = IntroCamera(
      self: _self.point,
      server: _serverPoint(vpn),
    );

    return Scaffold(
      backgroundColor: GlukColors.pageBg,
      body: Stack(
        children: <Widget>[
          // The wave study from the mock-up, instead of flat black.
          const Positioned.fill(child: PageBackground()),
          Positioned.fill(
            child: _Backdrop(
              morph: _morph,
              page: _page,
              motion: motion,
              camera: camera,
            ),
          ),
          // Keeps text legible over the dots without boxing the map in.
          const Positioned.fill(child: IgnorePointer(child: _StageFade())),

          // Both layers are laid out at full size, so sign-in has its final
          // layout on its very first frame. The old switcher centred whichever
          // child was entering, which is what made the form jump upwards.
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _morph,
              builder: (BuildContext context, Widget? _) {
                final double m = Curves.easeOutCubic.transform(_morph.value);
                return Stack(
                  children: <Widget>[
                    if (m < 0.999)
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: _showLogin,
                          child: Opacity(
                            opacity: (1 - m * 1.35).clamp(0.0, 1.0),
                            child: Transform.translate(
                              offset: Offset(0, -18 * m),
                              child: SafeArea(
                                child: _IntroPager(
                                  controller: _controller,
                                  page: _page,
                                  pages: _pages,
                                  onNext: _next,
                                  onSkip: _openLogin,
                                  self: _self,
                                  serverFlag: countryFlag(
                                    vpn.selectedNode?.countryCode ?? 'DE',
                                  ),
                                  serverName: vpn.selectedNode?.country ??
                                      'Germany',
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (m > 0.001)
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: !_showLogin,
                          child: ExcludeFocus(
                            excluding: !_showLogin,
                            child: Opacity(
                              opacity: ((m - 0.25) / 0.75).clamp(0.0, 1.0),
                              child: Transform.translate(
                                offset: Offset(0, 14 * (1 - m)),
                                child: SafeArea(
                                  child: LoginView(onBack: _backToIntro),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The world behind everything: one planet, one camera, and the unroll into the
/// full-bleed map that sign-in sits on.
class _Backdrop extends StatelessWidget {
  const _Backdrop({
    required this.morph,
    required this.page,
    required this.motion,
    required this.camera,
  });

  final Animation<double> morph;
  final ValueNotifier<double> page;
  final MotionController motion;
  final IntroCamera camera;

  @override
  Widget build(BuildContext context) {
    return _SceneClock(
      reduceMotion: motion.reduceMotion,
      builder: (BuildContext context, double seconds) {
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            return AnimatedBuilder(
              animation: Listenable.merge(<Listenable>[morph, page]),
              builder: (BuildContext context, Widget? _) {
                final Size viewport = constraints.biggest;
                final double m = Curves.easeInOutCubic.transform(morph.value);
                final double p = page.value.clamp(0.0, 2.0);
                final IntroFrame frame = camera.at(p);

                // Every phase here is derived from one forward-running clock,
                // and each is a whole number of turns per cycle, so nothing
                // snaps when it wraps. The globe used to travel 126 degrees
                // over a 30 s loop and then jump back to zero: that jolt is
                // what read as the planet twitching to restart the story.
                final double spin = seconds / 150 * 360;
                final double orbit = seconds / 14 % 1;
                final double dash = seconds / 1.4 % 1;
                final double pulse = seconds / 2.4 % 1;

                // Signing in unrolls the sphere into the flat map, and lands on
                // the same camera the home screen uses - so the composition
                // behind the form is the one the app keeps afterwards.
                final MapPoint mid = MapPoint(
                  (camera.self.x + camera.server.x) / 2,
                  (camera.self.y + camera.server.y) / 2,
                );
                final FlatMapView flat = FlatMapView.topAnchored(
                  viewport: viewport,
                  centreOn: mid,
                  coverage: 0.86,
                  topPadding: -viewport.height * 0.06,
                );
                final double zoom = lerpDouble(frame.zoom, flat.zoom, m)!;
                final Offset focus = Offset.lerp(
                  Offset(mid.fx, (mid.fy + 0.06).clamp(0.0, 1.0)),
                  flat.focus,
                  m,
                )!;

                return Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: IgnorePointer(
                        child: _Aurora(page: p, morph: m, motion: motion),
                      ),
                    ),
                    // The halo travels with the planet, so the light stays
                    // attached to the sphere as the camera moves.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: (1 - m).clamp(0.0, 1.0),
                          child: Align(
                            alignment: Alignment(
                              frame.anchor.dx * 2 - 1,
                              frame.anchor.dy * 2 - 1,
                            ),
                            child: _Halo(
                              motion: motion,
                              scale: 0.85 + 0.42 * p,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: DottedWorld(
                        globeness: 1 - m,
                        rotationDegrees: spin,
                        centreLongitude: frame.longitude,
                        centreLatitude: frame.latitude,
                        globeAnchor: Offset.lerp(
                          frame.anchor,
                          const Offset(0.5, 0.42),
                          m,
                        )!,
                        // The flat map has no edge to reach: it repeats every
                        // 360 degrees of longitude, so it can drift for ever.
                        driftDegrees: spin * 0.6,
                        zoom: zoom,
                        focus: focus,
                        dotOpacity: lerpDouble(frame.dotOpacity, 0.52, m)!,
                        selfPoint: camera.self,
                        selfOpacity: math.max(camera.selfOpacity(p), m),
                        serverPoint: camera.server,
                        serverOpacity: math.max(camera.serverOpacity(p), m),
                        arcProgress: math.max(camera.routeProgress(p), m),
                        arcPhase: dash,
                        orbitalPhase: orbit,
                        // The crowd is on stage the whole way through, and
                        // steps back a little once the user's own route is
                        // drawn so that thread is the one being read.
                        showcase:
                            lerpDouble(1, 0.78, camera.routeProgress(p))! *
                                (1 - 0.12 * m),
                        showcaseSeconds: seconds,
                        pulse: pulse,
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

/// A monotonic clock for the scene, in seconds.
///
/// The stage used to hang off looping animations, which is right for a pulse and
/// wrong for a story: a loop has to return to where it started, and the moment
/// it does, the whole world visibly resets. A clock only counts forward, so the
/// planet turns, threads come and go, and nothing ever snaps back.
///
/// With motion reduced it holds at a fixed second - a still frame with several
/// links already up, rather than an empty stage.
class _SceneClock extends StatefulWidget {
  const _SceneClock({required this.reduceMotion, required this.builder});

  final bool reduceMotion;
  final Widget Function(BuildContext context, double seconds) builder;

  /// Where the still frame sits when motion is reduced.
  static const double restingSeconds = 7.5;

  @override
  State<_SceneClock> createState() => _SceneClockState();
}

class _SceneClockState extends State<_SceneClock>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  double _seconds = _SceneClock.restingSeconds;

  @override
  void initState() {
    super.initState();
    if (!widget.reduceMotion) _ticker.start();
  }

  @override
  void didUpdateWidget(_SceneClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduceMotion == oldWidget.reduceMotion) return;
    if (widget.reduceMotion) {
      _ticker.stop();
    } else {
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final double next =
        _SceneClock.restingSeconds + elapsed.inMilliseconds / 1000;
    // The scene wants a repaint per frame; setState is not free, so drop the
    // ones that could not change a pixel.
    if ((next - _seconds).abs() < 1 / 60) return;
    setState(() => _seconds = next);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _seconds);
}

/// Two soft violet/blue lobes drifting behind the planet.
class _Aurora extends StatelessWidget {
  const _Aurora({
    required this.page,
    required this.morph,
    required this.motion,
  });

  final double page;
  final double morph;
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
              left: -120 + page * -46 + drift * 14,
              top: 30 + page * -34 + morph * 40,
              child: _blob(GlukColors.violet.withOpacity(0.20), 320),
            ),
            Positioned(
              right: -140 + page * 34 - drift * 18,
              top: 220 + page * 44 + morph * -30,
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

/// Top and bottom veils. Not a frame around the map: the world runs to every
/// edge and simply loses light where the copy needs contrast.
class _StageFade extends StatelessWidget {
  const _StageFade();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color(0x8C05040A),
            Color(0x1405040A),
            Color(0x00000000),
            Color(0xA605040A),
            Color(0xE605040A),
          ],
          stops: <double>[0, 0.18, 0.46, 0.82, 1],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}

class _IntroPager extends StatelessWidget {
  const _IntroPager({
    required this.controller,
    required this.page,
    required this.pages,
    required this.onNext,
    required this.onSkip,
    required this.self,
    required this.serverFlag,
    required this.serverName,
  });

  final PageController controller;
  final ValueNotifier<double> page;
  final int pages;
  final VoidCallback onNext;
  final VoidCallback onSkip;
  final SelfLocation self;
  final String serverFlag;
  final String serverName;

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
                  final bool last = value > pages - 1.35;
                  return AnimatedOpacity(
                    opacity: last ? 0 : 1,
                    duration: const Duration(milliseconds: 200),
                    child: TextButton(
                      onPressed: last ? null : onSkip,
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
                  return _Panel(
                    delta: index - value,
                    index: index,
                    self: self,
                    serverFlag: serverFlag,
                    serverName: serverName,
                  );
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

/// One intro beat. [delta] is its distance from the centre of the viewport:
/// 0 = centred, -1 = one page to the left, 1 = one page to the right.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.delta,
    required this.index,
    required this.self,
    required this.serverFlag,
    required this.serverName,
  });

  final double delta;
  final int index;
  final SelfLocation self;
  final String serverFlag;
  final String serverName;

  /// eyebrow, first line, accent line, body.
  List<String> get _copy {
    switch (index) {
      case 0:
        return <String>[
          'Global access',
          'Access the world with',
          'Super Fast VPN Servers\u2026',
          'Reach any of our locations in a tap and browse as if you were there.',
        ];
      case 1:
        return <String>[
          self.countryName == null ? 'You are here' : 'You \u00b7 ${self.countryName}',
          'This is where',
          'you are right now',
          'Approximate, and worked out from your device region and network - '
              'GlukVPN asks for no GPS and no location permission.',
        ];
      default:
        return <String>[
          'Route \u00b7 $serverName',
          'One tap and',
          "you're through",
          'Your traffic leaves from $serverName over an encrypted WireGuard '
              'tunnel. Secure route, no logs of the sites you visit.',
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final List<String> copy = _copy;
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (index == 1 && self.countryCode != null) ...<Widget>[
                    Text(self.flag, style: const TextStyle(fontSize: 12)),
                    const SizedBox(width: 6),
                  ],
                  if (index == 2) ...<Widget>[
                    Text(serverFlag, style: const TextStyle(fontSize: 12)),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    copy[0].toUpperCase(),
                    style: text.labelSmall?.copyWith(
                      color: GlukColors.violetLight,
                      letterSpacing: 1.1,
                    ),
                  ),
                ],
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
