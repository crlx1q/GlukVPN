import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../widgets/glass.dart';
import '../../widgets/skeleton.dart';

/// A single labelled metric in the desktop HUD (PUBLIC IP, PING, TRAFFIC…).
///
/// Matches the density of the approved visual language: tiny uppercase label,
/// large value, glass background.
///
/// ROUND 26: [loading] swaps the value for a shimmer of [skeletonCharacters]
/// so the statistics screen does not flash zeros while the history is still
/// being read from disk.
class MetricCell extends StatelessWidget {
  const MetricCell({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.icon,
    this.trailing,
    this.monospace = false,
    this.compact = false,
    this.loading = false,
    this.skeletonCharacters = 8,
    this.animate = true,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final IconData? icon;
  final Widget? trailing;

  /// Use for IPs and byte counters so digits do not jitter.
  final bool monospace;

  /// Tighter padding for the mini tray panel.
  final bool compact;

  /// Draw a skeleton in place of [value].
  final bool loading;

  /// Width of the skeleton, in characters of the value's font.
  final int skeletonCharacters;

  /// False under reduce-motion: the skeleton then holds still.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final TextStyle valueStyle = TextStyle(
      color: valueColor ?? GlukColors.text0,
      fontSize: compact ? 14 : 17,
      fontWeight: FontWeight.w600,
      fontFeatures: monospace
          ? const <FontFeature>[FontFeature.tabularFigures()]
          : null,
    );

    return GlassPanel(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 16,
        vertical: compact ? 10 : 14,
      ),
      radius: GlukSizes.cellRadius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 12, color: GlukColors.text2),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: GlukColors.text2,
                    fontSize: compact ? 9 : 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          SizedBox(height: compact ? 4 : 6),
          if (loading)
            SkeletonText(
              characters: skeletonCharacters,
              style: valueStyle,
              animate: animate,
            )
          else
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: valueStyle,
            ),
        ],
      ),
    );
  }
}

/// Lays metric cells out in an evenly spaced row.
class MetricRow extends StatelessWidget {
  const MetricRow({super.key, required this.children, this.spacing = 10});

  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) items.add(SizedBox(width: spacing));
      items.add(Expanded(child: children[i]));
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: items,
    );
  }
}
