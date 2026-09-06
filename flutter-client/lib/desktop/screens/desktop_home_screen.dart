import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/device_limit.dart';
import '../../models/models.dart';
import '../../services/ping_service.dart';
import '../../state/auth_controller.dart';
import '../../state/account_insights_controller.dart';
import '../../theme/tokens.dart';
import '../../utils/format.dart';
import '../../widgets/active_account_map.dart';
import '../../utils/geo.dart';
import '../i18n/desktop_strings.dart';
import '../logic/connection_phase.dart';
import '../logic/node_selector.dart';
import '../state/desktop_vpn_controller.dart';
import '../theme/desktop_theme.dart';
import '../widgets/desktop_connect_button.dart';
import '../widgets/device_limit_sheet.dart';
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
    required this.flatMap,
    required this.onToggleFlatMap,
    required this.onOpenServers,
  });

  final DesktopVpnController vpn;
  final AuthController auth;
  final DesktopStrings strings;
  final bool reduceMotion;

  /// ROUND 28: draw the world flat instead of folding it into a globe on
  /// connect. Persisted in DesktopSettings, so it survives a restart.
  final bool flatMap;
  final VoidCallback onToggleFlatMap;
  final VoidCallback onOpenServers;

  @override
  State<DesktopHomeScreen> createState() => _DesktopHomeScreenState();
}

class _DesktopHomeScreenState extends State<DesktopHomeScreen> with WidgetsBindingObserver {
  Timer? _tick;
  late AccountInsightsController _accountMap;
  void _onAccountMapChanged() { if (mounted) setState(() {}); }
  @override void didChangeAppLifecycleState(AppLifecycleState state) => _accountMap.setVisible(state == AppLifecycleState.resumed);

  /// The device-limit picker is a modal, so it must be pushed exactly once per
  /// verdict: the controller notifies on every status poll, and without this
  /// guard the dialog would stack on top of itself several times a second.
  bool _deviceLimitOpen = false;

  /// The user closed the picker without freeing anything. The banner keeps its
  /// "Free the slot" button, but nothing pops up again on its own.
  bool _deviceLimitDismissed = false;

  @override
  void initState() {
    super.initState();
    _accountMap = AccountInsightsController(widget.vpn.api);
    _accountMap.addListener(_onAccountMapChanged);
    _accountMap.setVisible(true);
    WidgetsBinding.instance.addObserver(this);
    // The duration readout has to advance once a second; the controller only
    // notifies on real state changes, which is correct but not enough here.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (widget.vpn.phase.isConnected) setState(() {});
    });
    widget.vpn.addListener(_onVpnChanged);
    // The verdict can predate this screen. The window is surfaced from the
    // tray *because* the limit was hit, and a Home that mounts only then would
    // otherwise sit and wait for a notification that has already been sent.
    if (widget.vpn.deviceLimitBlocked) {
      scheduleMicrotask(() {
        if (mounted) unawaited(_openDeviceLimit());
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _accountMap.removeListener(_onAccountMapChanged);
    _accountMap.dispose();
    widget.vpn.removeListener(_onVpnChanged);
    super.dispose();
  }

  void _onVpnChanged() {
    if (!mounted) return;
    if (!widget.vpn.deviceLimitBlocked) {
      // Either a slot was freed or the verdict was dropped: arm the automatic
      // prompt again for the next time the account fills up.
      _deviceLimitDismissed = false;
      return;
    }
    if (_deviceLimitOpen || _deviceLimitDismissed) return;
    // The verdict arrives from inside notifyListeners(), i.e. during a build or
    // a state change, and a route cannot be pushed from there.
    scheduleMicrotask(() {
      if (mounted) unawaited(_openDeviceLimit());
    });
  }

  /// Shows the picker and, once a slot is free, connects this PC straight away
  /// - which is the entire point of the dialog. Pressing Connect again would
  /// only repeat the refusal the user just resolved.
  Future<void> _openDeviceLimit() async {
    final DeviceLimitDetails? limit = widget.vpn.deviceLimit;
    if (_deviceLimitOpen || limit == null || !limit.isActionable) return;
    _deviceLimitOpen = true;
    try {
      final bool freed = await showDeviceLimitSheet(
        context: context,
        strings: widget.strings,
        details: limit,
        api: widget.vpn.api,
        onRelease: widget.vpn.freeDeviceSlot,
      );
      if (!mounted) return;
      if (freed) {
        await widget.vpn.connect();
      } else {
        _deviceLimitDismissed = true;
      }
    } finally {
      _deviceLimitOpen = false;
    }
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
          accountMap: _accountMap,
          vpn: vpn,
          strings: s,
          reduceMotion: widget.reduceMotion,
          self: self,
          serverPoint: serverPoint,
          nodePoints: nodePoints,
          flatMap: widget.flatMap,
          onToggleFlatMap: widget.onToggleFlatMap,
          onOpenServers: widget.onOpenServers,
        );

        final Widget rail = _MetricsRail(
          vpn: vpn,
          strings: s,
          reduceMotion: widget.reduceMotion,
        );
        final Widget banner = _HomeBanner(
          vpn: vpn,
          strings: s,
          onFreeSlot: () => unawaited(_openDeviceLimit()),
        );

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
  final AccountInsightsController accountMap;
  const _MapCard({
    required this.accountMap,
    required this.vpn,
    required this.strings,
    required this.reduceMotion,
    required this.self,
    required this.serverPoint,
    required this.nodePoints,
    required this.flatMap,
    required this.onToggleFlatMap,
    required this.onOpenServers,
  });

  final DesktopVpnController vpn;
  final DesktopStrings strings;
  final bool reduceMotion;
  final SelfLocation? self;
  final MapPoint? serverPoint;
  final List<MapPoint> nodePoints;
  final bool flatMap;
  final VoidCallback onToggleFlatMap;
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
                    accountArcs: accountMapArcs(accountMap.snapshot),
                    height: c.maxHeight,
                    // Fills the card instead of leaving empty bands above and
                    // below a thin strip of dots.
                    zoomBoost: flatMap ? 1.05 : 1.62,
                    forceFlat: flatMap,
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

            Positioned(
              top: 14, right: 14,
              child: AccountDevicesButton(controller: accountMap, russian: s.isRussian),
            ),

            // Globe <-> flat map, bottom right.
            //
            // ROUND 28. Connecting folds the world into a ball, which is a
            // good reveal and a bad map: the far half rotates out of sight,
            // and with a European node that is often the user's own dot. The
            // control sits where a zoom control sits on any map, and lifts
            // clear of the server pill below it.
            Positioned(
              right: 14,
              bottom: 86,
              child: _MapModeButton(
                flat: flatMap,
                russian: s.isRussian,
                onTap: onToggleFlatMap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The globe/flat-map switch in the corner of the map card.
///
/// Deliberately not an [IconButton]: the desktop theme kills ripples, so the
/// stock button gives no feedback at all on a dark card. A hover ring reads
/// correctly with a mouse, which is the only pointer this client has.
class _MapModeButton extends StatefulWidget {
  const _MapModeButton({
    required this.flat,
    required this.russian,
    required this.onTap,
  });

  final bool flat;
  final bool russian;
  final VoidCallback onTap;

  @override
  State<_MapModeButton> createState() => _MapModeButtonState();
}

class _MapModeButtonState extends State<_MapModeButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // The label names what the button *does*, not what is on screen now, and
    // the icon matches it. A globe icon on a globe would be a status readout,
    // not a control.
    final String label = widget.russian
        ? (widget.flat ? 'Свернуть в планету' : 'Развернуть карту')
        : (widget.flat ? 'Collapse to planet' : 'Expand world map');

    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: _hovered
                    ? DesktopTokens.cardHover
                    : DesktopTokens.cardRaised.withOpacity(0.86),
                shape: BoxShape.circle,
                border: Border.all(
                  color: _hovered
                      ? GlukColors.violetLight.withOpacity(0.55)
                      : DesktopTokens.cardBorder,
                ),
              ),
              child: Center(
                child: Icon(
                  widget.flat ? Icons.public_rounded : Icons.map_rounded,
                  size: 19,
                  color: _hovered ? GlukColors.text0 : GlukColors.text1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Right rail
// ---------------------------------------------------------------------------

class _MetricsRail extends StatelessWidget {
  const _MetricsRail({
    required this.vpn,
    required this.strings,
    required this.reduceMotion,
  });

  final DesktopVpnController vpn;
  final DesktopStrings strings;
  final bool reduceMotion;

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
    final ConnectionPhase phase = vpn.phase;
    final bool connected = phase.isConnected;
    final bool connecting = phase == ConnectionPhase.connecting;
    final bool animate = !reduceMotion;

    // ROUND 26: three honest states per value.
    //
    //  * connecting - every value is on its way: skeletons, never the old
    //    tunnel address or the home IP;
    //  * connected but not measured yet - skeleton until the probe answers;
    //  * anything else - a dash, except the public IP, which is the home
    //    address once the probe has answered, and the counters, which are 0 B.
    //
    // vpn.vpnIp is null outside connecting/connected by construction, so the
    // address of a tunnel that is already gone cannot reach this card.
    final String? publicIp = vpn.publicIp;
    final String? vpnIp = vpn.vpnIp;
    final Duration? duration = connected ? vpn.connectedFor : null;
    final int? ping = connected ? vpn.currentPingMs : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InfoCard(
          title: s.isRussian ? 'Соединение' : 'Connection',
          accent: connected ? GlukColors.connected : null,
          rows: <InfoRow>[
            InfoRow(
              label: s.publicIp,
              value: connecting ? null : publicIp,
              loading: connecting || (connected && publicIp == null),
              skeletonCharacters: 15,
              animate: animate,
              emptyLabel: s.dash,
            ),
            InfoRow(
              label: s.vpnIp,
              value: connecting ? null : vpnIp,
              loading: connecting || (connected && vpnIp == null),
              skeletonCharacters: 15,
              animate: animate,
              emptyLabel: s.dash,
              valueColor: connected ? GlukColors.connected : null,
            ),
            InfoRow(
              label: s.duration,
              value: duration == null ? null : formatDuration(duration),
              loading: connecting || (connected && duration == null),
              skeletonCharacters: 8,
              animate: animate,
              emptyLabel: s.dash,
            ),
            InfoRow(
              label: s.ping,
              value: ping == null ? null : formatPing(ping),
              loading: connecting || (connected && ping == null),
              skeletonCharacters: 5,
              animate: animate,
              emptyLabel: s.dash,
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
  const _HomeBanner({
    required this.vpn,
    required this.strings,
    required this.onFreeSlot,
  });

  final DesktopVpnController vpn;
  final DesktopStrings strings;

  /// Opens the device-limit picker. Owned by the screen's State, because a
  /// dialog needs a context that outlives this stateless rebuild.
  final VoidCallback onFreeSlot;

  @override
  Widget build(BuildContext context) {
    final DesktopStrings s = strings;
    final bool ru = s.isRussian;
    final ConnectionPhase phase = vpn.phase;

    void copyLog() {
      Clipboard.setData(ClipboardData(text: vpn.diagnosticsDump()));
    }

    final String copyLabel = ru ? 'Копировать журнал' : 'Copy log';

    // ROUND 26: the raw verifier code (handshake_pending, bringing_up) used to
    // be printed as the subtitle. It is translated here, and worded for the
    // engine that is actually running - a sing-box tunnel has no WireGuard
    // handshake to wait for.
    final String? detail =
        s.describeStatusDetail(vpn.statusDetail, vpn.engine);

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
      // The one failure that can be fixed from this screen: every device slot
      // is taken and the server named the devices holding them. "Try again"
      // would only reproduce the same refusal, so the action opens the picker.
      final DeviceLimitDetails? limit =
          vpn.deviceLimitBlocked ? vpn.deviceLimit : null;
      return SecureBanner(
        tone: SecureTone.danger,
        title: limit == null
            ? s.phaseLabel(phase)
            : s.deviceLimitTitle(limit.usage),
        subtitle: limit == null
            ? (vpn.userMessage ??
                detail ??
                (ru ? 'Не удалось подключиться' : 'Could not connect'))
            : s.deviceLimitBody,
        actionLabel: limit == null ? s.retry : s.deviceLimitFreeSlot,
        onAction: limit == null ? () => vpn.connect() : onFreeSlot,
        secondaryActionLabel: copyLabel,
        onSecondaryAction: copyLog,
      );
    }

    // 5. Busy.
    if (phase.isBusy) {
      return SecureBanner(
        tone: SecureTone.warning,
        title: s.phaseLabel(phase),
        subtitle: detail ??
            s.describeStatusDetail('bringing_up', vpn.engine) ??
            vpn.statusDetail,
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
