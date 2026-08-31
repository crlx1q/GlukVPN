import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../theme/desktop_theme.dart';

/// The floating state capsule above the globe (CONNECTED / CONNECTING / ...).
///
/// Deliberately the only place the connection state is spelled out in the map
/// card, so the composition stays as calm as the approved reference: one pill,
/// one location line, one button, one server row.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.dense = false,
    this.pulsing = false,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final bool dense;

  /// Slow breathing glow, used while the tunnel is coming up.
  final bool pulsing;

  @override
  Widget build(BuildContext context) {
    final Widget pill = AnimatedContainer(
      duration: GlukMotion.screen,
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 12 : 18,
        vertical: dense ? 6 : 9,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.13),
        borderRadius: BorderRadius.circular(DesktopTokens.pillRadius),
        border: Border.all(color: color.withOpacity(0.38), width: 1),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: color.withOpacity(0.18),
            blurRadius: 18,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: dense ? 12 : 14, color: color),
            SizedBox(width: dense ? 6 : 8),
          ],
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: color,
              fontSize: dense ? 11 : 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );

    if (!pulsing) return pill;

    return _Breathing(child: pill);
  }
}

/// Small opacity breath. Cheap enough to leave running while connecting and
/// stopped entirely the moment the phase settles.
class _Breathing extends StatefulWidget {
  const _Breathing({required this.child});

  final Widget child;

  @override
  State<_Breathing> createState() => _BreathingState();
}

class _BreathingState extends State<_Breathing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.62, end: 1.0).animate(
        CurvedAnimation(parent: _c, curve: Curves.easeInOut),
      ),
      child: widget.child,
    );
  }
}

/// "You  KZ  Aqmola, Kazakhstan" line under the status pill.
class LocationLine extends StatelessWidget {
  const LocationLine({
    super.key,
    required this.youLabel,
    required this.place,
    this.flag,
  });

  final String youLabel;
  final String place;
  final String? flag;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(
          Icons.place_outlined,
          size: 14,
          color: GlukColors.text2,
        ),
        const SizedBox(width: 6),
        Text(
          youLabel,
          style: const TextStyle(
            color: GlukColors.text1,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            decoration: TextDecoration.none,
          ),
        ),
        const SizedBox(width: 8),
        if (flag != null && flag!.isNotEmpty) ...<Widget>[
          Text(
            flag!,
            style: const TextStyle(
              fontSize: 14,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(width: 7),
        ],
        Text(
          place,
          style: const TextStyle(
            color: GlukColors.text0,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.none,
          ),
        ),
      ],
    );
  }
}
