import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models/models.dart';
import '../state/auth_controller.dart';
import '../state/channel_controller.dart';
import '../state/vpn_controller.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../utils/format.dart' hide countryFlag;
import '../utils/geo.dart';
import '../widgets/connect_button.dart';
import '../widgets/dotted_world.dart';
import '../widgets/glass.dart';
import '../widgets/logo.dart';

/// The main screen: dotted world map behind a 150 px power button, a state
/// badge, the selected node, a 2x2 readout grid and the traffic panel.
///
/// Everything on it is real: the public IP comes from a probe made *through*
/// the tunnel, the VPN IP is the address the control plane leased, the duration
/// counts from the session's `connectedAt`, and the ping is an ICMP round-trip
/// to the node's gateway inside the tunnel (falling back to an HTTPS round-trip
/// to the control API, which is labelled differently so the number is never
/// passed off as tunnel latency).
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.onOpenServers,
    this.onOpenProfile,
  });

  final VoidCallback onOpenServers;
  final VoidCallback? onOpenProfile;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Computed once: locale/timezone only, no GPS and no geolocation request.
  late final SelfLocation _self = approximateSelfLocation();

  Future<void> _toggle(VpnController vpn) async {
    if (vpn.busy) return;
    if (vpn.isConnected) {
      await vpn.disconnect();
    } else if (!vpn.isTransitioning) {
      await vpn.connect();
    }
  }

  ConnectPhase _phaseFor(VpnUiState state) {
    switch (state) {
      case VpnUiState.connected:
        return ConnectPhase.connected;
      case VpnUiState.connecting:
        return ConnectPhase.connecting;
      case VpnUiState.disconnecting:
        return ConnectPhase.disconnecting;
      case VpnUiState.disconnected:
        return ConnectPhase.idle;
    }
  }

  @override
  Widget build(BuildContext context) {
    final VpnController vpn = context.watch<VpnController>();
    final AuthController auth = context.watch<AuthController>();
    final MotionController motion = context.watch<MotionController>();
    final TextTheme text = Theme.of(context).textTheme;

    final VpnNodeInfo? node = vpn.selectedNode;
    final MapPoint? serverPoint = countryPoint(node?.countryCode);
    // Every node that is up right now, so the map shows the real fleet.
    final List<MapPoint> fleet = vpn.nodes
        .where((VpnNodeInfo item) => item.online)
        .map((VpnNodeInfo item) => countryPoint(item.countryCode))
        .whereType<MapPoint>()
        .toList();

    final (String badgeLabel, Color badgeTone) = switch (vpn.state) {
      VpnUiState.connected => ('connected', GlukColors.connected),
      VpnUiState.connecting => ('connecting', GlukColors.amber),
      VpnUiState.disconnecting => ('disconnecting', GlukColors.amber),
      VpnUiState.disconnected => ('inactive', GlukColors.text2),
    };

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: _MapBackdrop(
            motion: motion,
            selfPoint: _self.point,
            serverPoint: serverPoint,
            fleet: fleet,
            connected: vpn.isConnected,
            live: vpn.isConnected || vpn.state == VpnUiState.connecting,
          ),
        ),
        const Positioned.fill(child: IgnorePointer(child: _MapFade())),
        SafeArea(
          bottom: false,
          child: Column(
            children: <Widget>[
              _Header(
                username: auth.user?.username,
                publicIdLabel: auth.user?.publicIdLabel,
                onOpenProfile: widget.onOpenProfile,
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 108),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Center(
                        child: StatusBadge(
                          label: badgeLabel,
                          tone: badgeTone,
                          blinking: vpn.isTransitioning,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Center(
                        child: GlukConnectButton(
                          phase: _phaseFor(vpn.state),
                          reduceMotion: motion.reduceMotion,
                          onTap: vpn.busy ? null : () => _toggle(vpn),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _ServerRow(
                        node: node,
                        loading: vpn.loadingNodes,
                        onTap: widget.onOpenServers,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: StatCell(
                              label: 'Public IP',
                              value: vpn.exitIp ?? '\u2014',
                              valueColor:
                                  vpn.isConnected ? GlukColors.connected : null,
                            ),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: StatCell(
                              label: 'VPN IP',
                              value: vpn.assignedIp ?? '\u2014 . \u2014 . \u2014 . \u2014',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 9),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: StatCell(
                              label: 'Duration',
                              value: vpn.isConnected
                                  ? formatDuration(vpn.connectedFor)
                                  : '00:00:00',
                            ),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: StatCell(
                              label: 'Ping',
                              value: vpn.ping.milliseconds?.toString() ?? '\u2014',
                              trailing: Text(
                                vpn.ping.ok
                                    ? 'ms \u00b7 ${vpn.ping.sourceLabel}'
                                    : 'ms',
                                style: text.bodySmall,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 9),
                      _TrafficPanel(rx: vpn.bytesRx, tx: vpn.bytesTx),
                      if (node != null && !node.online) ...<Widget>[
                        const SizedBox(height: 12),
                        InlineNotice(
                          message: '${node.displayTitle} is offline right now. '
                              'Pick another server.',
                          tone: GlukColors.amber,
                        ),
                      ],
                      if (!auth.subscriptionActive) ...<Widget>[
                        const SizedBox(height: 12),
                        const InlineNotice(
                          message: 'Your plan is inactive, so new connections '
                              'are paused.',
                          tone: GlukColors.amber,
                        ),
                      ],
                      if (vpn.notice != null) ...<Widget>[
                        const SizedBox(height: 12),
                        InkWell(
                          onTap: vpn.clearMessages,
                          child: InlineNotice(
                            message: vpn.notice!,
                            tone: GlukColors.violetLight,
                          ),
                        ),
                      ],
                      if (vpn.error != null) ...<Widget>[
                        const SizedBox(height: 12),
                        InkWell(
                          onTap: vpn.clearMessages,
                          child: InlineNotice(message: vpn.error!),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The map, the "you" marker, the node marker and the animated cable between
/// them. `focus: (0.60, 0.30)` reproduces `object-position: 60% 30%`.
class _MapBackdrop extends StatelessWidget {
  const _MapBackdrop({
    required this.motion,
    required this.selfPoint,
    required this.serverPoint,
    required this.fleet,
    required this.connected,
    required this.live,
  });

  final MotionController motion;
  final MapPoint selfPoint;
  final MapPoint? serverPoint;
  final List<MapPoint> fleet;
  final bool connected;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: live ? 1 : 0),
      duration: motion.transition(const Duration(milliseconds: 900)),
      curve: Curves.easeOutCubic,
      builder: (BuildContext context, double arc, Widget? _) {
        return LoopingBuilder(
          duration: GlukMotion.connectionDash,
          reduceMotion: motion.reduceMotion,
          builder: (BuildContext context, double dash) {
            return LoopingBuilder(
              duration: GlukMotion.mapPulse,
              reduceMotion: motion.reduceMotion,
              frozenValue: 0.35,
              builder: (BuildContext context, double pulse) {
                return LoopingBuilder(
                  duration: const Duration(seconds: 14),
                  reduceMotion: motion.reduceMotion,
                  frozenValue: 0.2,
                  builder: (BuildContext context, double orbit) {
                    // One turn of longitude every four minutes. Imperceptible
                    // frame to frame, but it is the difference between a world
                    // and wallpaper - and a full 360 loop wraps seamlessly.
                    return LoopingBuilder(
                      duration: const Duration(seconds: 240),
                      reduceMotion: motion.reduceMotion,
                      frozenValue: 0,
                      builder: (BuildContext context, double drift) {
                        return DottedWorld(
                          // Bigger and higher than before: the planet anchors
                          // the top of the composition instead of sitting
                          // behind the readouts.
                          zoom: 1.85,
                          focus: const Offset(0.52, 0.19),
                          dotOpacity: 0.58,
                          driftDegrees: drift * 360,
                          selfPoint: selfPoint,
                          serverPoint: serverPoint,
                          nodePoints: fleet,
                          arcProgress: arc,
                          arcPhase: dash,
                          orbitalPhase: orbit,
                          pulse: live ? pulse : 0,
                          connected: connected,
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/// `.map-stage` mask - the map fades out towards the bottom so the readouts sit
/// on a calm background.
class _MapFade extends StatelessWidget {
  const _MapFade();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color(0x000A0714),
            Color(0x660A0714),
            Color(0xF20A0714),
          ],
          stops: <double>[0, 0.50, 0.86],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.username,
    required this.publicIdLabel,
    required this.onOpenProfile,
  });

  final String? username;
  final String? publicIdLabel;
  final VoidCallback? onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ChannelController channel = context.watch<ChannelController>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 6),
      child: Row(
        children: <Widget>[
          const GlukLogo(size: 34, glow: false),
          const SizedBox(width: 10),
          Text('GlukVPN', style: text.titleMedium),
          // Internal builds only. A release APK talks to a single control plane
          // and never labels itself.
          if (AppConfig.betaChannelAvailable && channel.isBeta) ...<Widget>[
            const SizedBox(width: 8),
            _BetaTag(label: channel.versionOf(channel.active)?.label ?? 'BETA'),
          ],
          const Spacer(),
          _ProfileChip(
            username: username,
            publicIdLabel: publicIdLabel,
            onTap: onOpenProfile,
          ),
        ],
      ),
    );
  }
}

/// Amber, never violet: on BETA you are talking to a different database, and
/// the badge has to be impossible to confuse with production.
class _BetaTag extends StatelessWidget {
  const _BetaTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: GlukColors.amber.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: GlukColors.amber.withOpacity(0.45)),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: GlukColors.amber, fontSize: 10),
      ),
    );
  }
}

class _ProfileChip extends StatelessWidget {
  const _ProfileChip({
    required this.username,
    required this.publicIdLabel,
    required this.onTap,
  });

  final String? username;
  final String? publicIdLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final String name = username ?? 'account';
    final String initial =
        name.isEmpty ? '?' : name.characters.first.toUpperCase();

    return GlassPanel(
      radius: 999,
      padding: const EdgeInsets.fromLTRB(6, 5, 12, 5),
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: GlukGradients.arrow,
            ),
            child: Text(
              initial,
              style: text.labelSmall?.copyWith(color: GlukColors.bg),
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(name, style: text.bodySmall?.copyWith(color: GlukColors.text0)),
              if (publicIdLabel != null && publicIdLabel!.isNotEmpty)
                Text(
                  publicIdLabel!,
                  style: text.bodySmall?.copyWith(fontSize: 9.5),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `.power-btn` - 150 px, radial `#201A30 -> #0A0812`, with the glow behind it
/// (`.blob-glow` / `glowPulse`) tinted green once the tunnel is up.
class _PowerButton extends StatelessWidget {
  const _PowerButton({
    required this.state,
    required this.motion,
    required this.onTap,
  });

  final VpnUiState state;
  final MotionController motion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool connected = state == VpnUiState.connected;
    final bool transitioning =
        state == VpnUiState.connecting || state == VpnUiState.disconnecting;
    final Color glow = connected ? GlukColors.connected : GlukColors.violet;

    return SizedBox(
      width: GlukSizes.blobGlow,
      height: GlukSizes.blobGlow,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          LoopingBuilder(
            duration: GlukMotion.glowPulse,
            reduceMotion: motion.reduceMotion,
            frozenValue: 0.5,
            reverse: true,
            builder: (BuildContext context, double t) {
              final double scale = 0.84 + 0.16 * t;
              return Container(
                width: GlukSizes.blobGlow * scale,
                height: GlukSizes.blobGlow * scale,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: <Color>[
                      glow.withOpacity(connected ? 0.34 : 0.18),
                      glow.withOpacity(0),
                    ],
                    stops: const <double>[0.22, 1],
                  ),
                ),
              );
            },
          ),
          Semantics(
            button: true,
            label: connected ? 'Disconnect' : 'Connect',
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: Container(
                  width: GlukSizes.powerButton,
                  height: GlukSizes.powerButton,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: GlukGradients.powerButton,
                    border: Border.all(
                      color: connected
                          ? GlukColors.connected.withOpacity(0.55)
                          : GlukColors.stroke,
                      width: 1.2,
                    ),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: glow.withOpacity(connected ? 0.42 : 0.20),
                        blurRadius: 38,
                        spreadRadius: 1,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: transitioning
                      ? SizedBox(
                          width: 30,
                          height: 30,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: GlukColors.violetLight,
                          ),
                        )
                      : Icon(
                          Icons.power_settings_new_rounded,
                          size: 40,
                          color: connected
                              ? GlukColors.connected
                              : GlukColors.powerGlyph,
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

/// The selected node, tappable straight through to the server list.
class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.node,
    required this.loading,
    required this.onTap,
  });

  final VpnNodeInfo? node;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    if (node == null) {
      return GlassPanel(
        radius: 999,
        padding: const EdgeInsets.fromLTRB(10, 9, 14, 9),
        onTap: onTap,
        child: Row(
          children: <Widget>[
            const FlagCircle(flag: '\u{1F310}'),
            const SizedBox(width: 10),
            Text(
              loading ? 'Loading servers\u2026' : 'No server available',
              style: text.titleMedium,
            ),
            const Spacer(),
            const Icon(Icons.chevron_right_rounded, color: GlukColors.text2),
          ],
        ),
      );
    }

    return GlassPanel(
      radius: 999,
      padding: const EdgeInsets.fromLTRB(10, 9, 14, 9),
      onTap: onTap,
      child: Row(
        children: <Widget>[
          FlagCircle(flag: countryFlag(node!.countryCode)),
          const SizedBox(width: 10),
          Text(node!.displayTitle, style: text.titleMedium),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '\u00b7 ${node!.displaySubtitle}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall,
            ),
          ),
          const Spacer(),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: node!.online ? GlukColors.connected : GlukColors.text2,
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right_rounded, color: GlukColors.text2),
        ],
      ),
    );
  }
}

/// `.traffic` - WireGuard's own byte counters, reported by the node agent.
class _TrafficPanel extends StatelessWidget {
  const _TrafficPanel({required this.rx, required this.tx});

  final int rx;
  final int tx;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return GlassPanel(
      radius: GlukSizes.trafficRadius,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.swap_vert_rounded, size: 15, color: GlukColors.text2),
              const SizedBox(width: 6),
              Text('Traffic'.toUpperCase(), style: text.labelMedium),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: _TrafficItem(
                  icon: Icons.south_rounded,
                  label: 'Downloaded',
                  value: formatBytes(rx),
                  tone: GlukColors.violetLight,
                ),
              ),
              Expanded(
                child: _TrafficItem(
                  icon: Icons.north_rounded,
                  label: 'Uploaded',
                  value: formatBytes(tx),
                  tone: GlukColors.blue,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TrafficItem extends StatelessWidget {
  const _TrafficItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.tone,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 13, color: tone),
            const SizedBox(width: 5),
            Text(label, style: text.bodySmall),
          ],
        ),
        const SizedBox(height: 4),
        Text(value, style: text.labelLarge),
      ],
    );
  }
}
