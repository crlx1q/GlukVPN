import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../utils/format.dart';
import '../../utils/signal.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../../widgets/signal_bars.dart';

/// One selectable server in the desktop list (requirement 8).
///
/// Shows only user-facing geography: country, city, region, load, signal and
/// ping. Internal node names and IDs are never rendered — [VpnNodeInfo]'s
/// displayTitle/displaySubtitle deliberately exclude them.
class ServerRow extends StatefulWidget {
  const ServerRow({
    super.key,
    required this.node,
    required this.selected,
    this.onTap,
    this.pingMs,
    this.locked = false,
    this.loadLabel,
    this.offlineLabel,
  });

  final VpnNodeInfo node;
  final bool selected;
  final VoidCallback? onTap;
  final int? pingMs;

  /// True on a Free plan, where manual selection is not available.
  final bool locked;

  final String? loadLabel;
  final String? offlineLabel;

  @override
  State<ServerRow> createState() => _ServerRowState();
}

class _ServerRowState extends State<ServerRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final available = node.online && node.connectable;
    final enabled = available && !widget.locked && widget.onTap != null;

    final strength = signalStrengthFor(
      online: node.online,
      available: available,
      pingMs: widget.pingMs,
      loadPercent: node.loadPercent,
    );

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: GlukMotion.screen,
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(GlukSizes.cellRadius),
            border: Border.all(
              color: widget.selected
                  ? GlukColors.violet.withOpacity(0.55)
                  : (_hovered && enabled
                      ? GlukColors.stroke
                      : Colors.transparent),
            ),
          ),
          child: Opacity(
            opacity: available ? 1 : 0.45,
            child: GlassPanel(
              radius: GlukSizes.cellRadius,
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              color: widget.selected ? GlukColors.violet.withOpacity(0.10) : Colors.transparent,
              child: Row(
                children: <Widget>[
                  FlagCircle(flag: node.countryCode, size: GlukSizes.flagCircle),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          node.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: widget.selected
                                ? GlukColors.text0
                                : GlukColors.text0.withOpacity(0.92),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _subtitle(),
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
                  const SizedBox(width: 10),
                  if (widget.pingMs != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Text(
                        formatPing(widget.pingMs!),
                        style: TextStyle(
                          color: _pingColor(widget.pingMs!),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ),
                  SignalBars(strength: strength, height: 16),
                  if (widget.locked) ...<Widget>[
                    const SizedBox(width: 10),
                    const Icon(
                      Icons.lock_outline_rounded,
                      size: 15,
                      color: GlukColors.text2,
                    ),
                  ] else if (widget.selected) ...<Widget>[
                    const SizedBox(width: 10),
                    const Icon(
                      Icons.check_circle_rounded,
                      size: 17,
                      color: GlukColors.violetLight,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle() {
    final node = widget.node;
    if (!node.online) {
      return widget.offlineLabel ?? 'Offline';
    }
    final parts = <String>[node.displaySubtitle];
    final load = node.loadPercent;
    if (load != null) {
      parts.add('${widget.loadLabel ?? 'Load'} ${formatPercent(load.toDouble())}');
    }
    return parts.where((String p) => p.isNotEmpty).join('  ·  ');
  }

  Color _pingColor(int ms) {
    switch (pingLevelFor(ms)) {
      case PingLevel.excellent:
        return GlukColors.connected;
      case PingLevel.medium:
        return GlukColors.amber;
      case PingLevel.low:
        return GlukColors.danger;
      default:
        return GlukColors.text2;
    }
  }
}


