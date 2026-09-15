import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../utils/format.dart';
import '../../utils/signal.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../../widgets/load_bar.dart';
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
    this.unreachable = false,
    this.locked = false,
    this.loadLabel,
    this.offlineLabel,
    this.russian = true,
  });

  final VpnNodeInfo node;
  final bool selected;
  final VoidCallback? onTap;
  final int? pingMs;

  /// Узел не ответил на мини-пинг: бары серые, в строке «нет ответа».
  ///
  /// Выбор при этом НЕ блокируется: молчание на ICMP — факт про
  /// замер, а не про работоспособность туннеля.
  final bool unreachable;

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
    final String status = _status();

    final strength = signalStrengthFor(
      online: node.online,
      // Узел, не ответивший на замер, становится серым сразу, а не
      // показывает «две палки по умолчанию».
      available: available && !widget.unreachable,
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
            // Только сама строка сервера: список запретов больше не висит
            // под каждым сервером — его свод в «Расширенных» настройках,
            // один раз на всю сеть, а не N раз в списке.
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
                        const SizedBox(height: 3),
                        // Либо статус, либо шкала загрузки с процентом — тот же
                        // элемент, что `.load-bar` в расширении, а не ещё одна
                        // серая строка текста.
                        if (status.isNotEmpty)
                          Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: GlukColors.text2,
                              fontSize: 11,
                            ),
                          )
                        else
                          Row(
                            children: <Widget>[
                              NodeLoadBar(percent: node.loadPercent),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  '${widget.loadLabel ?? 'Load'} '
                                  '${formatPercent(node.loadPercent.toDouble())}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: GlukColors.text2,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Порядок как в расширении: деления, затем цифра. Место
                  // под цифру занято всегда: без замера там серое тире,
                  // иначе строка перестраивалась при каждом ответе узла.
                  SignalBars(strength: strength, height: 16),
                  const SizedBox(width: 9),
                  SizedBox(
                    width: 52,
                    child: Text(
                      widget.pingMs == null
                          ? '—'
                          : formatPing(widget.pingMs, russian: widget.russian),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: widget.pingMs == null
                            ? GlukColors.text2
                            : _pingColor(widget.pingMs!),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
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

  /// Статус строкой — только когда ему есть что сказать. Загрузка ушла
  /// в шкалу рядом, а город и страна уже написаны в названии выше.
  String _status() {
    final node = widget.node;
    if (!node.online) {
      return widget.offlineLabel ?? 'Offline';
    }
    final parts = <String>[];
    if (widget.pingMs == null && widget.unreachable) {
      parts.add(widget.russian ? 'нет ответа' : 'no reply');
    }
    if (node.maintenance) parts.add(widget.russian ? 'Технические работы' : 'Maintenance');
    // Запретов здесь нет: в одну строку они не влезали, а их свод
    // теперь целиком в «Расширенных» настройках.
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
