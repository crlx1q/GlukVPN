import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../widgets/connect_button.dart';
import '../i18n/desktop_strings.dart';
import '../logic/connection_phase.dart';

/// Desktop wrapper around the existing morphing [ConnectButton].
///
/// Requirement 6: keep the current blob/morph animation and colour language,
/// only adapt the scale and add a desktop-appropriate status caption. The
/// underlying widget is shared verbatim with Android.
class DesktopConnectButton extends StatelessWidget {
  const DesktopConnectButton({
    super.key,
    required this.phase,
    required this.strings,
    this.onTap,
    this.reduceMotion = false,
    this.size = 168,
    this.showLabel = true,
  });

  final ConnectionPhase phase;
  final DesktopStrings strings;
  final VoidCallback? onTap;
  final bool reduceMotion;
  final double size;
  final bool showLabel;

  Color get _accent {
    if (phase.isConnected) return GlukColors.connected;
    if (phase.isError) return GlukColors.danger;
    if (phase.isBusy) return GlukColors.amber;
    return GlukColors.violet;
  }

  String get _actionLabel {
    if (phase.isConnected) return strings.disconnect;
    if (phase == ConnectionPhase.connecting) return strings.cancel;
    if (phase.isError) return strings.retry;
    return strings.connect;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = phase.connectEnabled || phase == ConnectionPhase.connecting;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: size,
          height: size,
          child: FittedBox(
            fit: BoxFit.contain,
            child: Opacity(
              opacity: enabled ? 1 : 0.55,
              child: ConnectButton(
                phase: phase.buttonPhase,
                reduceMotion: reduceMotion,
                onTap: enabled ? onTap : null,
              ),
            ),
          ),
        ),
        if (showLabel) ...<Widget>[
          const SizedBox(height: 18),
          AnimatedDefaultTextStyle(
            duration: GlukMotion.screen,
            style: TextStyle(
              color: _accent,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.6,
            ),
            child: Text(strings.phaseLabel(phase).toUpperCase()),
          ),
          const SizedBox(height: 6),
          Text(
            _actionLabel,
            style: const TextStyle(
              color: GlukColors.text2,
              fontSize: 12,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ],
    );
  }
}
