import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../../widgets/logo.dart';
import '../i18n/desktop_strings.dart';
import '../logic/connection_phase.dart';
import '../logic/node_selector.dart';
import '../state/desktop_vpn_controller.dart';
import '../theme/desktop_theme.dart';
import '../widgets/desktop_connect_button.dart';
import '../widgets/status_pill.dart';

/// Tray quick panel.
///
/// One left click on the tray icon pops this up just above the notification
/// area, the way a native Windows utility panel does. A double click opens the
/// full window instead.
///
/// Contents are deliberately minimal, per the request: connect button, current
/// server, ping, download and upload. No navigation, no settings, no metrics
/// wall.
///
/// Two things changed after the first round of feedback:
///
///  * **No rounded container here.** The panel now fills the window edge to
///    edge with a flat fill, and the corners are rounded by DWM instead (see
///    WindowFx.applyPanelChrome). Rounding the content while the window has its
///    own radius and its own Windows 11 border is what produced the glowing
///    strips along the sides.
///  * **The connect button owns the slack.** It sits in an Expanded, so any
///    leftover height makes the button area breathe instead of leaving a dead
///    band at the bottom.
class MiniPanel extends StatelessWidget {
  const MiniPanel({
    super.key,
    required this.vpn,
    required this.strings,
    required this.reduceMotion,
    required this.onExpand,
    required this.onHide,
  });

  final DesktopVpnController vpn;
  final DesktopStrings strings;
  final bool reduceMotion;
  final VoidCallback onExpand;
  final VoidCallback onHide;

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

    final String serverTitle = node == null
        ? s.autoBestServer
        : publicNodeTitle(node, fallback: s.autoBestServer);

    return ColoredBox(
      color: const Color(0xFF0B0813),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(13, 9, 13, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Header doubles as the drag handle.
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: onExpand,
              child: Row(
                children: <Widget>[
                  const GlukLogo(size: 20, radius: 6),
                  const SizedBox(width: 8),
                  const Text(
                    'GlukVPN',
                    style: TextStyle(
                      color: GlukColors.text1,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.7,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const Spacer(),
                  CircleIconButton(
                    icon: Icons.open_in_full_rounded,
                    tooltip: s.trayOpen,
                    size: 24,
                    onTap: onExpand,
                  ),
                  const SizedBox(width: 5),
                  CircleIconButton(
                    icon: Icons.close_rounded,
                    tooltip: s.cancel,
                    size: 24,
                    onTap: onHide,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 9),

            Center(
              child: StatusPill(
                label: s.phaseLabel(phase),
                color: _accent,
                dense: true,
                pulsing: phase.isBusy && !reduceMotion,
              ),
            ),

            // The button takes whatever height is left over, so the panel never
            // shows an empty band under the content.
            Expanded(
              child: Center(
                child: DesktopConnectButton(
                  phase: phase,
                  strings: s,
                  reduceMotion: reduceMotion,
                  size: 134,
                  showLabel: false,
                  onTap: () => vpn.toggle(),
                ),
              ),
            ),

            // Server + ping on one compact row.
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: DesktopTokens.cardRaised,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: DesktopTokens.cardBorder),
              ),
              child: Row(
                children: <Widget>[
                  FlagCircle(flag: node?.countryCode ?? '\u{1F310}', size: 20),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      serverTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: GlukColors.text0,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                  Text(
                    vpn.currentPingMs == null
                        ? s.dash
                        : formatPing(vpn.currentPingMs!),
                    style: const TextStyle(
                      color: GlukColors.text1,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.none,
                      fontFeatures: <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // Download / upload.
            Row(
              children: <Widget>[
                Expanded(
                  child: _MiniStat(
                    icon: Icons.south_rounded,
                    value: formatBytes(vpn.rxBytes),
                    tint: GlukColors.connected,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniStat(
                    icon: Icons.north_rounded,
                    value: formatBytes(vpn.txBytes),
                    tint: GlukColors.violetLight,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.icon,
    required this.value,
    required this.tint,
  });

  final IconData icon;
  final String value;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: DesktopTokens.cardRaised,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: DesktopTokens.cardBorder),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 13, color: tint),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: GlukColors.text0,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.none,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
