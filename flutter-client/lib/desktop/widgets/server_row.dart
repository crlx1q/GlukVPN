import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../utils/format.dart';
import '../../utils/signal.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../../widgets/signal_bars.dart';
import '../logic/node_selector.dart';

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
    this.russian = true,
  });

  final VpnNodeInfo node;
  final bool selected;
  final VoidCallback? onTap;
  final int? pingMs;

  /// True on a Free plan, where manual selection is not available.
  final bool locked;

  final String? loadLabel;
  final String? offlineLabel;

  /// Language for the geography label. ROUND 5: rows read "Frankfurt,
  /// Германия" instead of a bare "DE".
  final bool russian;

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
            // Строка сервера плюс сложенный список запретов под ней —
            // тот же вид, что в расширении, на телефоне и в админке.
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
            GlassPanel(
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
                          publicNodeLocation(node, russian: widget.russian),
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
                if (node.restrictions.isNotEmpty)
                  _NodeLimitsPanel(node: node, russian: widget.russian),
              ],
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
    // The title already spells out city and country, so the second line is
    // just load and status now instead of repeating the city.
    final parts = <String>[];
    parts.add('${widget.loadLabel ?? 'Load'} ${formatPercent(node.loadPercent.toDouble())}');
    if (node.maintenance) parts.add(widget.russian ? 'Технические работы' : 'Maintenance');
    // Запреты ушли из этой строки в раскрывающийся список ниже:
    // в одну строку они не влезали и обрезались многоточием.
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

/// «Что запрещено на этом сервере» — сложенный список под строкой
/// сервера. Свёрнуто — одна строка со счётчиком, раскрыто — запрет,
/// правила за ним и короткий комментарий почему. Один и тот же вид
/// в расширении, на телефоне и в админке.
class _NodeLimitsPanel extends StatefulWidget {
  const _NodeLimitsPanel({required this.node, required this.russian});

  final VpnNodeInfo node;
  final bool russian;

  @override
  State<_NodeLimitsPanel> createState() => _NodeLimitsPanelState();
}

class _NodeLimitsPanelState extends State<_NodeLimitsPanel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final List<NodeRestriction> items = widget.node.restrictions;
    final bool ru = widget.russian;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    ru
                        ? 'Запрещено здесь \u00b7 ${items.length}'
                        : 'Blocked here \u00b7 ${items.length}',
                    style: const TextStyle(
                      color: GlukColors.amber,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: GlukColors.amber,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(GlukSizes.cellRadius),
                border: Border.all(color: GlukColors.amber.withOpacity(0.18)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final NodeRestriction r in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            r.localizedLabel(ru),
                            style: const TextStyle(
                              color: GlukColors.amber,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (r.rulesLine.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                r.rulesLine,
                                style: const TextStyle(color: GlukColors.text2, fontSize: 10),
                              ),
                            ),
                          if (r.localizedDetail(ru).isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                r.localizedDetail(ru),
                                style: const TextStyle(
                                  color: GlukColors.text2,
                                  fontSize: 11,
                                  height: 1.35,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}


