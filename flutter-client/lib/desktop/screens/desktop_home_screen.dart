import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/models.dart';
import '../../services/ping_service.dart';
import '../../state/auth_controller.dart';
import '../../theme/tokens.dart';
import '../../utils/format.dart';
import '../../utils/geo.dart';
import '../i18n/desktop_strings.dart';
import '../logic/connection_phase.dart';
import '../logic/node_selector.dart';
import '../state/desktop_vpn_controller.dart';
import '../theme/desktop_theme.dart';
import '../widgets/desktop_connect_button.dart';
import '../widgets/info_panel.dart';
import '../widgets/secure_banner.dart';
import '../widgets/server_pill.dart';
import '../widgets/status_pill.dart';
import '../widgets/world_stage.dart';

/// Desktop home screen.
///
/// Composition, straight from the approved reference:
///   * one large map card holding the state pill, the location line, the
///     connect button and the server selector,
///   * a right rail with the CONNECTION and TRAFFIC cards,
///   * a full-width strip at the bottom that is reassuring when the tunnel is
///     up and becomes the problem/diagnostics surface when it is not.
///
/// The previous version scattered the button, four metric tiles and a traffic
/// panel down a narrow column beside an oversized empty map, which is what made
/// the window look unfinished.
class DesktopHomeScreen extends StatefulWidget {
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
  State<DesktopHomeScreen> createState() => _DesktopHomeScreenState();
}

class _DesktopHomeScreenState extends State<DesktopHomeScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The duration readout has to advance once a second; the controller only
    // notifies on real state changes, which is correct but not enough here.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (widget.vpn.phase.isConnected) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  DesktopStrings get s => widget.strings;
  DesktopVpnController get vpn => widget.vpn;

  @override
  Widget build(BuildContext context) {
    final AuthUser? user = widget.auth.user;

    final SelfLocation? self = approximateSelfLocation(
      originCountryCode: user?.originCountryCode,
      originCountryName: user?.originCountry,
      originRegion: user?.originRegion,
    );

    final VpnNodeInfo? node = vpn.selectedNode;
    final MapPoint? serverPoint =
        node == null ? null : countryPoint(node.countryCode);

    final List<MapPoint> nodePoints = <MapPoint>[
      for (final VpnNodeInfo n in vpn.userVisibleNodes)
        if (countryPoint(n.countryCode) != null) countryPoint(n.countryCode)!,
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // ROUND 5: 700, not 900.
        //
        // The window is a fixed 1000x780 panel, so the content area is
        // 1000 - 208 sidebar - 36 padding = 756 px. Against the old 900
        // threshold the three-column composition never engaged and the page
        // collapsed into one tall column - map on top, connection block under
        // it, traffic below that - with empty bands above and below the map.
        // That is exactly the screenshot the user held against the mockup.
        final bool wide = constraints.maxWidth >= 700;

        final Widget mapCard = _MapCard(
          vpn: vpn,
          strings: s,
          reduceMotion: widget.reduceMotion,
          self: self,
          serverPoint: serverPoint,
          nodePoints: nodePoints,
          onOpenServers: widget.onOpenServers,
        );

        final Widget rail = _MetricsRail(vpn: vpn, strings: s);
        final Widget banner = _HomeBanner(vpn: vpn, strings: s);

        if (!wide) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(DesktopTokens.pagePadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(height: 420, child: mapCard),
                const SizedBox(height: DesktopTokens.gutter),
                rail,
                const SizedBox(height: DesktopTokens.gutter),
                banner,
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(
            0,
            0,
            DesktopTokens.pagePadding,
            DesktopTokens.pagePadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: mapCard),
                    const SizedBox(width: DesktopTokens.gutter),
                    SizedBox(
                      width: DesktopTokens.rightRailWidth,
                      child: rail,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: DesktopTokens.gutter),
              banner,
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Map card
// ---------------------------------------------------------------------------

class _MapCard extends StatelessWidget {
  const _MapCard({
    required this.vpn,
    required this.strings,
    required this.reduceMotion,
    required this.self,
    required this.serverPoint,
    required this.nodePoints,
    required this.onOpenServers,
  });

  final DesktopVpnController vpn;
  final DesktopStrings strings;
  final bool reduceMotion;
  final SelfLocation? self;
  final MapPoint? serverPoint;
  final List<MapPoint> nodePoints;
  final VoidCallback onOpenServers;

  Color get _accent {
    final ConnectionPhase phase = vpn.phase;
    if (phase.isConnected) return GlukColors.connected;
    if (phase.isError) return GlukColors.danger;
    if (phase.isBusy) return GlukColors.amber;
    return GlukColors.violetLight;
  }

  @override
  Widget build(BuildContext context) {
    final DesktopStrings s = strings;
    final ConnectionPhase phase = vpn.phase;
    final VpnNodeInfo? node = vpn.selectedNode;

    // ROUND 5: "Frankfurt, Германия" - city first, country second, both run
    // through the shared dictionary. publicNodeLocation instead of
    // publicNodeTitle: an internal-looking node is still usable, but its handle
    // must never reach the screen, and a bare "DE" is not a place name.
    final String serverTitle = node == null
        ? s.autoBestServer
        : publicNodeLocation(
            node,
            russian: s.isRussian,
            fallback: s.autoBestServer,
          );

    // Never repeat the title as the subtitle: an empty second line is better
    // than "Auto - Best server" printed twice, which is what the first build
    // did whenever no node had been resolved yet.
    String? serverSubtitle;
    if (node == null) {
      serverSubtitle = vpn.autoSelectionEnabled ? s.autoDescription : null;
    } else {
      // The title already carries both city and country, so a subtitle that
      // repeats either half would print the same place twice.
      final String sub = publicNodeSubtitle(node) ?? '';
      serverSubtitle = (sub.isEmpty ||
              serverTitle.toLowerCase().contains(sub.toLowerCase()))
          ? null
          : sub;
      if (vpn.autoSelectionEnabled) {
        serverSubtitle = serverSubtitle == null
            ? s.autoBestServer
            : '${s.autoBestServer} \u00b7 $serverSubtitle';
      }
    }

    return Container(
      decoration: DesktopTokens.cardDecoration(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(DesktopTokens.cardRadius - 1),
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  return WorldStage(
                    phase: phase,
                    reduceMotion: reduceMotion,
                    selfLocation: self,
                    serverPoint: serverPoint,
                    allNodes: nodePoints,
                    height: c.maxHeight,
                    // Fills the card instead of leaving empty bands above and
                    // below a thin strip of dots.
                    zoomBoost: 1.35,
                  );
                },
              ),
            ),

            // State pill + location line.
            Positioned(
              top: 22,
              left: 0,
              right: 0,
              child: Column(
                children: <Widget>[
                  StatusPill(
                    label: s.phaseLabel(phase),
                    color: _accent,
                    icon: phase.isConnected
                        ? Icons.lock_rounded
                        : phase.isError
                            ? Icons.error_outline_rounded
                            : phase.isBusy
                                ? Icons.sync_rounded
                                : Icons.lock_open_rounded,
                    pulsing: phase.isBusy && !reduceMotion,
                  ),
                  if (self != null) ...<Widget>[
                    const SizedBox(height: 12),
                    LocationLine(
                      youLabel: s.isRussian ? 'Вы' : 'You',
                      place: self!.localizedPlace(russian: s.isRussian),
                      flag: self!.flag,
                      countryCode: self!.countryCode,
                    ),
                  ],
                ],
              ),
            ),

            // Dead centre, deliberately.
            //
            // The orbital rings, the halo and the radial bloom are all painted
            // around the middle of the stage. Nudging the button 10% lower is
            // what left those rings hanging above it, orbiting nothing. One
            // centre for every layer.
            Align(
              alignment: Alignment.center,
              child: DesktopConnectButton(
                phase: phase,
                strings: s,
                reduceMotion: reduceMotion,
                size: 248,
                showLabel: false,
                onTap: () => vpn.toggle(),
              ),
            ),

            // Server selector.
            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: ServerPill(
                    title: serverTitle,
                    subtitle: serverSubtitle,
                    flag: node?.countryCode,
                    online: node?.online ?? true,
                    locked: vpn.manualSelectionLocked,
                    pingMs: node == null ? null : vpn.pings[node.id],
                    onTap: onOpenServers,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Right rail
// ---------------------------------------------------------------------------

class _MetricsRail extends StatelessWidget {
  const _MetricsRail({required this.vpn, required this.strings});

  final DesktopVpnController vpn;
  final DesktopStrings strings;

  String _pingSourceLabel() {
    switch (vpn.pingSource) {
      case PingSource.tunnelGateway:
        return strings.tunnel;
      case PingSource.controlApi:
        return strings.viaApi;
      case PingSource.none:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final DesktopStrings s = strings;
    final bool connected = vpn.phase.isConnected;
    final Duration? duration = vpn.connectedFor;
    final int? ping = vpn.currentPingMs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InfoCard(
          title: s.isRussian ? 'Соединение' : 'Connection',
          accent: connected ? GlukColors.connected : null,
          rows: <InfoRow>[
            InfoRow(
              label: s.publicIp,
              value: vpn.publicIp ?? s.dash,
            ),
            InfoRow(
              label: s.vpnIp,
              value: vpn.snapshot.vpnIp ?? s.dash,
              valueColor: connected ? GlukColors.connected : null,
            ),
            InfoRow(
              label: s.duration,
              value: duration == null ? s.dash : formatDuration(duration),
            ),
            InfoRow(
              label: s.ping,
              value: ping == null ? s.dash : formatPing(ping),
              unit: ping == null ? null : _pingSourceLabel(),
            ),
          ],
        ),
        const SizedBox(height: DesktopTokens.gutter),
        InfoCard(
          title: s.traffic,
          rows: <InfoRow>[
            InfoRow(
              label: s.downloaded,
              value: formatBytes(vpn.rxBytes),
              icon: Icons.south_rounded,
              iconColor: GlukColors.connected,
              compact: true,
            ),
            InfoRow(
              label: s.uploaded,
              value: formatBytes(vpn.txBytes),
              icon: Icons.north_rounded,
              iconColor: GlukColors.violetLight,
              compact: true,
            ),
          ],
        ),
        const Spacer(),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom strip: reassurance, or the one place a failure is explained
// ---------------------------------------------------------------------------

class _HomeBanner extends StatelessWidget {
  const _HomeBanner({required this.vpn, required this.strings});

  final DesktopVpnController vpn;
  final DesktopStrings strings;

  @override
  Widget build(BuildContext context) {
    final DesktopStrings s = strings;
    final bool ru = s.isRussian;
    final ConnectionPhase phase = vpn.phase;

    void copyLog() {
      Clipboard.setData(ClipboardData(text: vpn.diagnosticsDump()));
    }

    final String copyLabel = ru ? 'Копировать журнал' : 'Copy log';

    // 1. Tunnel is verified up: the calm state from the reference.
    if (phase.isConnected) {
      return SecureBanner(
        tone: SecureTone.secure,
        title: ru ? 'Соединение защищено' : 'Your connection is secure',
        subtitle: ru
            ? 'Приватный и быстрый интернет через туннель GlukVPN'
            : 'Enjoy private and fast internet',
      );
    }

    // 2. The privileged tunnel service cannot be reached: nothing else matters
    //    until this is fixed, so it wins over every other message.
    if (!vpn.serviceReady) {
      return SecureBanner(
        tone: SecureTone.danger,
        title: s.serviceMissing,
        subtitle: vpn.serviceProblem ?? s.serviceMissingHint,
        actionLabel: ru ? 'Установить службу' : 'Install service',
        onAction: () => vpn.repairService(),
        secondaryActionLabel: copyLabel,
        onSecondaryAction: copyLog,
      );
    }

    // 3. The server list never arrived. This is exactly the failure that was
    //    invisible before: the list was empty and no reason was shown.
    if (vpn.nodesError != null && vpn.userVisibleNodes.isEmpty) {
      return SecureBanner(
        tone: SecureTone.warning,
        title: ru ? 'Серверы не загрузились' : 'Could not load servers',
        subtitle: vpn.nodesError!,
        actionLabel: vpn.nodesLoading
            ? (ru ? 'Обновляю…' : 'Refreshing…')
            : s.refresh,
        onAction: vpn.nodesLoading ? null : () => vpn.retryNodes(),
        secondaryActionLabel: copyLabel,
        onSecondaryAction: copyLog,
      );
    }

    // 4. A connect attempt failed, or the session/subscription is the problem.
    if (phase.isError) {
      return SecureBanner(
        tone: SecureTone.danger,
        title: s.phaseLabel(phase),
        subtitle: vpn.userMessage ??
            (vpn.statusDetail.isEmpty
                ? (ru ? 'Не удалось подключиться' : 'Could not connect')
                : vpn.statusDetail),
        actionLabel: s.retry,
        onAction: () => vpn.connect(),
        secondaryActionLabel: copyLabel,
        onSecondaryAction: copyLog,
      );
    }

    // 5. Busy.
    if (phase.isBusy) {
      return SecureBanner(
        tone: SecureTone.warning,
        title: s.phaseLabel(phase),
        subtitle: vpn.statusDetail.isEmpty
            ? (ru ? 'Поднимаю туннель…' : 'Bringing the tunnel up…')
            : vpn.statusDetail,
      );
    }

    // 6. Idle and healthy.
    return SecureBanner(
      tone: SecureTone.idle,
      title: ru ? 'Соединение не защищено' : 'You are not protected',
      subtitle: ru
          ? 'Нажмите кнопку включения, чтобы поднять VPN'
          : 'Press the power button to bring the VPN up',
      actionLabel: s.connect,
      onAction: () => vpn.connect(),
    );
  }
}
