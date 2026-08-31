import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../theme/desktop_theme.dart';

/// One label/value pair inside an [InfoCard].
///
/// Values use tabular figures so a ticking duration or byte counter never
/// shifts the layout sideways.
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.unit,
    this.icon,
    this.iconColor,
    this.compact = false,
  });

  final String label;
  final String value;
  final Color? valueColor;

  /// Rendered small and muted after the value, e.g. "ms · tunnel".
  final String? unit;

  /// Optional leading glyph, used by the traffic card's up/down arrows.
  final IconData? icon;
  final Color? iconColor;

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 10 : 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 14, color: iconColor ?? GlukColors.text2),
                const SizedBox(width: 7),
              ],
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GlukColors.text2,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 5 : 7),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: valueColor ?? GlukColors.text0,
                    fontSize: compact ? 16 : 19,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                    letterSpacing: -0.2,
                    decoration: TextDecoration.none,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
              if (unit != null && unit!.isNotEmpty) ...<Widget>[
                const SizedBox(width: 6),
                Text(
                  unit!,
                  style: const TextStyle(
                    color: GlukColors.text2,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// A titled card of [InfoRow]s with hairline separators, matching the
/// CONNECTION and TRAFFIC panels in the approved design.
class InfoCard extends StatelessWidget {
  const InfoCard({
    super.key,
    required this.title,
    required this.rows,
    this.trailing,
    this.accent,
  });

  final String title;
  final List<InfoRow> rows;
  final Widget? trailing;

  /// Tints the section caption, e.g. green while connected.
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final List<Widget> children = <Widget>[];

    for (int i = 0; i < rows.length; i++) {
      children.add(rows[i]);
      if (i != rows.length - 1) {
        children.add(
          const Divider(
            height: 1,
            thickness: 1,
            color: DesktopTokens.hairline,
          ),
        );
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      decoration: DesktopTokens.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: accent ?? GlukColors.text1,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    );
  }
}
