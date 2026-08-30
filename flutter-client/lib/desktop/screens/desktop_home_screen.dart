import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../state/auth_controller.dart';
import '../../theme/tokens.dart';
import '../../utils/format.dart';
import '../../utils/geo.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../i18n/desktop_strings.dart';
import '../logic/connection_phase.dart';
import '../state/desktop_vpn_controller.dart';
import '../widgets/desktop_connect_button.dart';
import '../widgets/metric_cell.dart';
import '../widgets/world_stage.dart';

/// Desktop home: globe on the left, connect + live metrics on the right.
///
/// Requirement 7 asks for a large living map that still feels dense, so the
/// layout is a two-column split rather than a stretched phone screen.
class DesktopHomeScreen extends StatelessWidget {
  const DesktopHomeScreen({
    super.key,
    required this.vpn,
    required this.auth,
    required this.strings,
    required this.reduceMotion,
    required this.onOpenServers,
  });

  final DesktopVpnController vpn;
  final AuthController auth;
  final DesktopStrings strings;
  final bool reduceMotion;
  final VoidCallback onOpenServers;

  @override
  Widget build(BuildContext context) {
    final s = strings;
    final phase = vpn.phase;
    final node = vpn.selectedNode;
    final user = auth.user;

    final self = approximateSelfLocation(
      originCountryCode: user?.originCountryCode,
      originCountry: user?.originCountry,
      originRegion: user?.originRegion,
    );

    final serverPoint =
        node == null ? null : countryPoint(node.countryCode);

    final nodePoints = <Offset>[
      for (final n in vpn.userVisibleNodes)
        if (countryPoint(n.countryCode) != null) countryPoint(n.countryCode)!,
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final wide = constraints.maxWidth >= 980;

        final stage = WorldStage(
          phase: phase,
          reduceMotion: reduceMotion,
          selfLocation: self,
          serverPoint: serverPoint,
          allNodes: nodePoints,
          height: wide ? constraints.maxHeight - 48 : 340,
        );

        final panel = _ControlPanel(
          vpn: vpn,
          strings: s,
          reduceMotion: reduceMotion,
          onOpenServers: onOpenServers,
          selfLabel: self?.placeLabel,
        );

        if (!wide) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(GlukSizes.pagePadding),
            child: Column(
              children: <Widget>[stage, const SizedBox(height: 20), panel],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.all(GlukSizes.pagePadding),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(flex: 6, child: stage),
              const SizedBox(width: 22),
              SizedBox(
                width: 348,
                child: SingleChildScrollView(child: panel),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ControlPanel extends StatelessWidget {
  const _ControlPanel({
    required this.vpn,
    required this.strings,
    required this.reduceMotion,
    required this.onOpenServers,
    this.selfLabel,
  });

  final DesktopVpnController vpn;
  final DesktopStrings strings;
  final bool reduceMotion;
  final VoidCallback onOpenServers;
  final String? selfLabel;

  @override
  Widget build(BuildContext context) {
    final s = strings;
    final phase = vpn.phase;
    final node = vpn.selectedNode;
    final snapshot = vpn.snapshot;
    final duration = vpn.connectedFor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (!vpn.serviceReady)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: InlineNotice(
              message: s.serviceMissingHint,
              tone: NoticeTone.danger,
            ),
          ),

        if (vpn.userMessage != null && vpn.serviceReady)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: InlineNotice(
              message: vpn.userMessage!,
              tone: phase.isError ? NoticeTone.danger : NoticeTone.info,
            ),
          ),

        // Connect button, unchanged visual language, desktop scale.
        Center(
          child: DesktopConnectButton(
            phase: phase,
            strings: s,
            reduceMotion: reduceMotion,
            onTap: () => vpn.toggle(),
          ),
        ),

        const SizedBox(height: 22),

        // Current server card doubles as the entry point to the selector.
        _ServerCard(
          node: node,
          strings: s,
          autoLabel: vpn.autoSelectionEnabled ? s.autoBestServer : null,
          onTap: onOpenServers,
        ),

        const SizedBox(height: 14),

        MetricRow(
          children: <Widget>[
            MetricCell(
              label: s.publicIp,
              value: vpn.publicIp ?? s.dash,
              monospace: true,
            ),
            MetricCell(
              label: s.vpnIp,
              value: snapshot.vpnIp ?? s.dash,
              monospace: true,
              valueColor:
                  phase.isConnected ? GlukColors.connected : null,
            ),
          ],
        ),

        const SizedBox(height: 10),

        MetricRow(
          children: <Widget>[
            MetricCell(
              label: s.duration,
              value: duration == null ? s.dash : formatDuration(duration),
              monospace: true,
            ),
            MetricCell(
              label: s.ping,
              value: vpn.currentPingMs == null
                  ? s.dash
                  : '${formatPing(vpn.currentPingMs!)} · ${_pingSourceLabel()}',
              monospace: true,
            ),
          ],
        ),

        const SizedBox(height: 10),

        GlassPanel(
          radius: GlukSizes.trafficRadius,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                s.traffic,
                style: const TextStyle(
                  color: GlukColors.text2,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _TrafficLeg(
                      icon: Icons.south_rounded,
                      label: s.downloaded,
                      value: formatBytes(vpn.rxBytes),
                      tint: GlukColors.connected,
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 30,
                    color: GlukColors.stroke,
                  ),
                  Expanded(
                    child: _TrafficLeg(
                      icon: Icons.north_rounded,
                      label: s.uploaded,
                      value: formatBytes(vpn.txBytes),
                      tint: GlukColors.violetLight,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        if (selfLabel != null) ...<Widget>[
          const SizedBox(height: 12),
          Center(
            child: Text(
              selfLabel!,
              style: const TextStyle(
                color: GlukColors.text2,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _pingSourceLabel() {
    switch (vpn.pingSource) {
      case PingSource.tunnelGateway:
        return strings.tunnel;
      case PingSource.controlApi:
        return strings.viaApi;
      case PingSource.none:
        return strings.dash;
    }
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.node,
    required this.strings,
    required this.onTap,
    this.autoLabel,
  });

  final VpnNodeInfo? node;
  final DesktopStrings strings;
  final VoidCallback onTap;
  final String? autoLabel;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: GlukSizes.cellRadius,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: <Widget>[
          FlagCircle(
            flag: node?.flag ?? '🌐',
            size: GlukSizes.flagCircle,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  node?.displayTitle ?? strings.autoBestServer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GlukColors.text0,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  autoLabel ?? node?.displaySubtitle ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GlukColors.text2,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: GlukColors.text2,
          ),
        ],
      ),
    );
  }
}

class _TrafficLeg extends StatelessWidget {
  const _TrafficLeg({
    required this.icon,
    required this.label,
    required this.value,
    required this.tint,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(icon, size: 15, color: tint),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: const TextStyle(color: GlukColors.text2, fontSize: 10),
            ),
            const SizedBox(height: 1),
            Text(
              value,
              style: const TextStyle(
                color: GlukColors.text0,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
