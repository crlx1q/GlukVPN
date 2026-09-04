import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../i18n/app_strings.dart';
import '../models/models.dart';
import '../state/auth_controller.dart';
import '../state/channel_controller.dart';
import '../state/vpn_controller.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../utils/format.dart' hide countryFlag;
import '../utils/geo.dart';
import '../utils/geo_dictionary.dart';
import '../utils/map_view.dart';
import '../widgets/connect_button.dart';
import '../widgets/dotted_world.dart';
import '../widgets/glass.dart';
import '../widgets/logo.dart';
import '../widgets/skeleton.dart';

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
  /// Where to draw "you".
  ///
  /// The control plane's own view of where the request came from goes first: it
  /// is the only source that can tell a Russian-language phone in Moscow from
  /// the same phone in Kazakhstan. The device's clock and locale are only the
  /// fallback. No GPS, no permission prompt, and never finer than a country.
  SelfLocation _selfFor(AuthUser? user) => approximateSelfLocation(
        originCountryCode: user?.originCountryCode,
        originCountryName: user?.originCountry,
        originRegion: user?.originRegion,
      );

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
    final AppStrings s = context.strings;
    final VpnController vpn = context.watch<VpnController>();
    final AuthController auth = context.watch<AuthController>();
    final MotionController motion = context.watch<MotionController>();
    final TextTheme text = Theme.of(context).textTheme;

    final VpnNodeInfo? node = vpn.selectedNode;
    final SelfLocation self = _selfFor(auth.user);
    final MapPoint? serverPoint = countryPoint(node?.countryCode);
    // Every node that is up right now, so the map shows the real fleet.
    final List<MapPoint> fleet = vpn.nodes
        .where((VpnNodeInfo item) => item.online)
        .map((VpnNodeInfo item) => countryPoint(item.countryCode))
        .whereType<MapPoint>()
        .toList();

    final (String badgeLabel, Color badgeTone) = switch (vpn.state) {
      VpnUiState.connected => (s.stateConnected, GlukColors.connected),
      VpnUiState.connecting => (s.stateConnecting, GlukColors.amber),
      VpnUiState.disconnecting => (s.stateDisconnecting, GlukColors.amber),
      VpnUiState.disconnected => (s.stateInactive, GlukColors.text2),
    };

    // The four readouts share one rule: a figure that is on its way is a
    // skeleton, a figure that does not apply is a dash, and nothing from the
    // previous session is ever shown in the gap. "On its way" is the whole of
    // connecting and disconnecting, plus the moments after the tunnel is up
    // while the exit address and the first ping are still out.
    final bool connected = vpn.isConnected;
    final bool transitioning = vpn.isTransitioning;
    final bool animate = !motion.reduceMotion;
    final String? pingText =
        connected ? vpn.ping.milliseconds?.toString() : null;

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: _MapBackdrop(
            motion: motion,
            selfPoint: self.point,
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
                      const SizedBox(height: 7),
                      Center(child: _LocationChip(self: self)),
                      const SizedBox(height: 7),
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
                        animate: animate,
                        onTap: widget.onOpenServers,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: StatCell(
                              label: s.publicIp,
                              child: ValueOrSkeleton(
                                // Exit address through the tunnel, or the
                                // phone's own address while disconnected -
                                // never one standing in for the other.
                                value: vpn.publicIp,
                                loading: transitioning ||
                                    (connected && vpn.exitIp == null),
                                characters: 15,
                                animate: animate,
                                style: StatCell.valueStyle(
                                  context,
                                  color: connected ? GlukColors.connected : null,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: StatCell(
                              label: s.vpnIp,
                              child: ValueOrSkeleton(
                                // The lease is only shown once the tunnel is
                                // up; while connecting it is a promise, not an
                                // address the phone is using.
                                value: connected ? vpn.assignedIp : null,
                                loading: transitioning ||
                                    (connected && vpn.assignedIp == null),
                                characters: 15,
                                animate: animate,
                                style: StatCell.valueStyle(context),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 9),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: StatCell(
                              label: s.duration,
                              child: ValueOrSkeleton(
                                value: connected
                                    ? formatDuration(vpn.connectedFor)
                                    : null,
                                loading: transitioning,
                                characters: 8,
                                emptyLabel: '00:00:00',
                                animate: animate,
                                style: StatCell.valueStyle(context),
                              ),
                            ),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: StatCell(
                              label: s.ping,
                              child: ValueOrSkeleton(
                                value: pingText,
                                loading: transitioning ||
                                    (connected && pingText == null),
                                characters: 5,
                                animate: animate,
                                style: StatCell.valueStyle(context),
                              ),
                              trailing: Text(
                                connected && vpn.ping.ok
                                    ? '${s.ms} \u00b7 ${vpn.ping.sourceLabel}'
                                    : s.ms,
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
                          message: s.nodeOffline(node.displayTitle),
                          tone: GlukColors.amber,
                        ),
                      ],
                      if (!auth.subscriptionActive) ...<Widget>[
                        const SizedBox(height: 12),
                        InlineNotice(
                          message: s.planInactiveNotice,
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
/// them.
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
    // The map is pinned to the top of the screen and covers most of its
    // height, so it reads as a world instead of a band sitting behind the
    // readouts. Those numbers depend on the viewport, so they are computed
    // rather than guessed - a hard-coded zoom is a strip on some phones and a
    // close-up on others. Framing runs between "you" and the chosen exit, so
    // the route you are about to take is what the picture is about.
    final MapPoint centre = serverPoint == null
        ? selfPoint
        : MapPoint(
            (selfPoint.x + serverPoint!.x) / 2,
            (selfPoint.y + serverPoint!.y) / 2,
          );
    final FlatMapView view = FlatMapView.topAnchored(
      viewport: MediaQuery.sizeOf(context),
      centreOn: centre,
      coverage: 0.88,
      topPadding: -6,
    );

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
                          zoom: view.zoom,
                          focus: view.focus,
                          dotOpacity: 0.58,
                          // ROUND 6: the map used to scroll one way for ever,
                          // like a marquee. Folding the 0 -> 1 drift into a
                          // triangle wave makes it travel out and then back,
                          // which is what the desktop client already does and
                          // what reads as a living map instead of a ticker.
                          driftDegrees:
                              (((drift <= 0.5
                                              ? drift * 2
                                              : (1 - drift) * 2) *
                                          24) -
                                      12),
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
            Color(0x1A0A0714),
            Color(0x8A0A0714),
            Color(0xD90A0714),
          ],
          stops: <double>[0, 0.38, 0.72, 1],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}

/// "Roughly here": where the connection appears to come from, as the control
/// plane saw it. Country-level, never a street, and never a permission prompt.
class _LocationChip extends StatelessWidget {
  const _LocationChip({required this.self});

  final SelfLocation self;

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    final TextTheme text = Theme.of(context).textTheme;
    final String flag = countryFlag(self.countryCode ?? '');

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(
          Icons.my_location_rounded,
          size: 12,
          color: GlukColors.text2,
        ),
        const SizedBox(width: 6),
        Text(
          s.you,
          style: text.bodySmall?.copyWith(color: GlukColors.text2),
        ),
        const SizedBox(width: 6),
        if (flag.isNotEmpty) ...<Widget>[
          Text(flag, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 5),
        ],
        Text(
          // Through the shared dictionary, so the country reads in the
          // interface language rather than always in English.
          self.localizedPlace(russian: s.isRussian),
          style: text.bodySmall?.copyWith(color: GlukColors.text1),
        ),
      ],
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
    final String name = username ?? context.strings.account.toLowerCase();
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

/// The selected node, tappable straight through to the server list.
class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.node,
    required this.loading,
    required this.animate,
    required this.onTap,
  });

  final VpnNodeInfo? node;
  final bool loading;

  /// False under reduce-motion: the loading skeleton then holds still.
  final bool animate;
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
            // A bar the size of a place name while the list loads: the row
            // keeps its shape and nothing has to be read and then unread.
            if (loading)
              SkeletonText(
                characters: 14,
                style: text.titleMedium,
                animate: animate,
              )
            else
              Text(context.strings.noServerAvailable, style: text.titleMedium),
            const Spacer(),
            const Icon(Icons.chevron_right_rounded, color: GlukColors.text2),
          ],
        ),
      );
    }

    // Country and city through the shared dictionary, like the server list,
    // so the chip reads "Германия · Франкфурт" on a Russian phone.
    final bool russian = context.strings.isRussian;
    final String title = localizeCountry(
      node!.countryCode,
      russian: russian,
      fallback: node!.displayTitle,
    );
    final String city = localizeCity(node!.city, russian: russian);
    final String subtitle = city.isNotEmpty ? city : node!.displaySubtitle;

    return GlassPanel(
      radius: 999,
      padding: const EdgeInsets.fromLTRB(10, 9, 14, 9),
      onTap: onTap,
      child: Row(
        children: <Widget>[
          FlagCircle(flag: countryFlag(node!.countryCode)),
          const SizedBox(width: 10),
          Text(title, style: text.titleMedium),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '\u00b7 $subtitle',
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
    final AppStrings s = context.strings;
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
              Text(s.traffic.toUpperCase(), style: text.labelMedium),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: _TrafficItem(
                  icon: Icons.south_rounded,
                  label: s.downloaded,
                  value: formatBytes(rx),
                  tone: GlukColors.violetLight,
                ),
              ),
              Expanded(
                child: _TrafficItem(
                  icon: Icons.north_rounded,
                  label: s.uploaded,
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
