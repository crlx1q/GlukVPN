import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../../widgets/logo.dart';
import '../i18n/desktop_strings.dart';
import '../logic/connection_phase.dart';
import '../state/desktop_vpn_controller.dart';
import '../widgets/desktop_connect_button.dart';

/// Compact quick panel opened by left-clicking the tray icon.
///
/// Requirement 10: status, connect, current server, ping, download/upload and
/// nothing else. No navigation — the goal is "click tray, see everything,
/// connect, close".
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

  @override
  Widget build(BuildContext context) {
    final s = strings;
    final phase = vpn.phase;
    final node = vpn.selectedNode;
    final duration = vpn.connectedFor;

    return ColoredBox(
      color: GlukColors.pageBg,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Header doubles as the drag handle.
            Row(
              children: <Widget>[
                const GlukLogo(size: 22, radius: 7),
                const SizedBox(width: 9),
                const Text(
                  'GlukVPN',
                  style: TextStyle(
                    color: GlukColors.text1,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                  ),
                ),
                const Spacer(),
                CircleIconButton(
                  icon: Icons.open_in_full_rounded,
                  tooltip: s.trayOpen,
                  size: 26,
                  onTap: onExpand,
                ),
                const SizedBox(width: 6),
                CircleIconButton(
                  icon: Icons.close_rounded,
                  tooltip: s.cancel,
                  size: 26,
                  onTap: onHide,
                ),
              ],
            ),

            const SizedBox(height: 14),

            Center(
              child: DesktopConnectButton(
                phase: phase,
                strings: s,
                reduceMotion: reduceMotion,
                size: 116,
                onTap: () => vpn.toggle(),
              ),
            ),

            const SizedBox(height: 14),

            GlassPanel(
              radius: 14,
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              child: Row(
                children: <Widget>[
                  FlagCircle(flag: node?.countryCode ?? '🌐', size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      node?.displayTitle ?? s.autoBestServer,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: GlukColors.text0,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    vpn.currentPingMs == null
                        ? s.dash
                        : formatPing(vpn.currentPingMs!),
                    style: const TextStyle(
                      color: GlukColors.text1,
                      fontSize: 11,
                      fontFeatures: <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 9),

            GlassPanel(
              radius: 14,
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 11,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: _MiniStat(
                      icon: Icons.south_rounded,
                      value: formatBytes(vpn.rxBytes),
                      tint: GlukColors.connected,
                    ),
                  ),
                  Expanded(
                    child: _MiniStat(
                      icon: Icons.north_rounded,
                      value: formatBytes(vpn.txBytes),
                      tint: GlukColors.violetLight,
                    ),
                  ),
                  Expanded(
                    child: _MiniStat(
                      icon: Icons.schedule_rounded,
                      value: duration == null
                          ? s.dash
                          : formatDuration(duration),
                      tint: GlukColors.text1,
                    ),
                  ),
                ],
              ),
            ),

            const Spacer(),

            if (vpn.userMessage != null && phase.isError)
              Text(
                vpn.userMessage!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: GlukColors.danger,
                  fontSize: 11,
                ),
              )
            else
              Text(
                vpn.snapshot.vpnIp ?? '',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: GlukColors.text2,
                  fontSize: 11,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 13, color: tint),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: GlukColors.text0,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
