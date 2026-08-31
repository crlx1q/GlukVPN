import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../utils/geo.dart';
import '../../widgets/dotted_world.dart';
import '../logic/connection_phase.dart';

/// The large living globe/map on the desktop home screen (requirement 7).
///
/// Reuses the existing [DottedWorld] painter from the mobile app — same dots,
/// same arc, same visual language — but drives it with a desktop-scale
/// composition and its own animation controllers so the mobile screens are
/// untouched.
class WorldStage extends StatefulWidget {
  const WorldStage({
    super.key,
    required this.phase,
    this.reduceMotion = false,
    this.selfLocation,
    this.serverPoint,
    this.allNodes = const <MapPoint>[],
    this.height = 420,
    this.zoomBoost = 1,
  });

  final ConnectionPhase phase;
  final bool reduceMotion;

  /// Approximate location of the user, from the account's origin country.
  final SelfLocation? selfLocation;

  /// Projected position of the selected VPN node.
  final MapPoint? serverPoint;

  /// Every visible node, drawn as faint dots.
  final List<MapPoint> allNodes;

  final double height;

  /// Extra zoom on top of the fit-to-width default.
  ///
  /// The map card is far taller than a 2:1 world map, so at zoom 1 the dots
  /// only covered the middle third of it and left the empty bands above and
  /// below that the user pointed out. Values above 1 fill the card without
  /// changing the projection or the marker positions.
  final double zoomBoost;

  @override
  State<WorldStage> createState() => _WorldStageState();
}

class _WorldStageState extends State<WorldStage>
    with TickerProviderStateMixin {
  late final AnimationController _spin;
  late final AnimationController _pulse;
  late final AnimationController _arc;
  late final AnimationController _orbit;

  /// Drives the flat-map <-> globe morph. 0 = flat map, 1 = globe.
  late final AnimationController _morph;

  @override
  void initState() {
    super.initState();

    _spin = AnimationController(
      vsync: this,
      duration: GlukMotion.globeSpin,
    );
    _pulse = AnimationController(
      vsync: this,
      duration: GlukMotion.haloPulse,
    );
    _arc = AnimationController(
      vsync: this,
      duration: GlukMotion.arcDash,
    );
    _orbit = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    );
    _morph = AnimationController(
      vsync: this,
      duration: GlukMotion.screen,
      value: widget.phase.isConnected ? 1 : 0,
    );

    _applyMotion();
  }

  @override
  void didUpdateWidget(covariant WorldStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase ||
        oldWidget.reduceMotion != widget.reduceMotion) {
      _applyMotion();
    }
  }

  /// Requirement 15: animations wind down when they are not needed, but the
  /// tunnel itself is never affected by this.
  void _applyMotion() {
    final connected = widget.phase.isConnected;
    final busy = widget.phase.isBusy;

    if (widget.reduceMotion) {
      _spin.stop();
      _pulse.stop();
      _orbit.stop();
      if (busy) {
        _arc.repeat();
      } else {
        _arc.stop();
      }
    } else {
      if (!_spin.isAnimating) _spin.repeat();
      if (!_orbit.isAnimating) _orbit.repeat();
      if (connected || busy) {
        if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
        if (!_arc.isAnimating) _arc.repeat();
      } else {
        _pulse.stop();
        _arc.stop();
      }
    }

    if (connected) {
      _morph.forward();
    } else {
      _morph.reverse();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _pulse.dispose();
    _arc.dispose();
    _orbit.dispose();
    _morph.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final self = widget.selfLocation?.point;
    final server = widget.serverPoint;
    final connected = widget.phase.isConnected;

    return SizedBox(
      height: widget.height,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // Soft violet bloom behind the globe, greenish once connected.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: Listenable.merge(<Listenable>[_pulse, _morph]),
                builder: (BuildContext context, Widget? child) {
                  final glow = 0.28 + (_pulse.value * 0.12);
                  final tint = Color.lerp(
                    GlukColors.violet,
                    GlukColors.connected,
                    _morph.value,
                  )!;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.center,
                        radius: 0.72,
                        colors: <Color>[
                          tint.withOpacity(glow * 0.5),
                          tint.withOpacity(glow * 0.16),
                          Colors.transparent,
                        ],
                        stops: const <double>[0.0, 0.45, 1.0],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          AnimatedBuilder(
            animation: Listenable.merge(<Listenable>[
              _spin,
              _pulse,
              _arc,
              _orbit,
              _morph,
            ]),
            builder: (BuildContext context, Widget? child) {
              return DottedWorld(
                globeness: _morph.value,
                rotationDegrees: _spin.value * 360,
                centreLongitude: _centreLongitude(self, server),
                centreLatitude: 12,
                driftDegrees: widget.reduceMotion ? 0 : (_orbit.value * 8) - 4,
                zoom: widget.zoomBoost * (1.0 + (_morph.value * 0.06)),
                dotOpacity: 0.55 + (_morph.value * 0.15),
                selfPoint: self,
                selfOpacity: self == null ? 0 : 1,
                serverPoint: server,
                serverOpacity: server == null ? 0 : _morph.value.clamp(0.35, 1),
                nodePoints: widget.allNodes,
                arcProgress: _arcProgress(),
                arcPhase: _arc.value,
                orbitalPhase: _orbit.value,
                pulse: _pulse.value,
                connected: connected,
              );
            },
          ),
        ],
      ),
    );
  }

  /// Keeps both endpoints of the route on screen.
  double _centreLongitude(MapPoint? self, MapPoint? server) {
    if (self == null && server == null) return 20;
    if (self == null) return _longitudeOf(server!);
    if (server == null) return _longitudeOf(self);
    return (_longitudeOf(self) + _longitudeOf(server)) / 2;
  }

  /// Converts a projected map point back to an approximate longitude.
  double _longitudeOf(MapPoint point) => (point.x / mapWidth) * 360 - 180;

  double _arcProgress() {
    if (widget.phase.isConnected) return 1;
    if (widget.phase == ConnectionPhase.connecting) return _arc.value;
    if (widget.phase == ConnectionPhase.disconnecting) return 1 - _arc.value;
    return 0;
  }
}
