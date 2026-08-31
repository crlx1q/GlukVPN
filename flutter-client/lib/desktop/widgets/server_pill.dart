import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../theme/desktop_theme.dart';

/// The wide server selector sitting under the connect button.
///
/// Shows only user-facing geography (flag, country, city). Internal node
/// handles never reach this widget: the caller passes pre-sanitised display
/// strings from `VpnNodeInfo.displayTitle` / `displaySubtitle`.
class ServerPill extends StatefulWidget {
  const ServerPill({
    super.key,
    required this.title,
    this.subtitle,
    this.flag,
    this.online = true,
    this.locked = false,
    this.pingMs,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final String? flag;
  final bool online;

  /// Free plans cannot pick a server manually; the row still opens the list so
  /// the user can see what a subscription unlocks.
  final bool locked;

  final int? pingMs;
  final VoidCallback? onTap;

  @override
  State<ServerPill> createState() => _ServerPillState();
}

class _ServerPillState extends State<ServerPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color dot = widget.online ? GlukColors.connected : GlukColors.text2;

    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            color: _hovered
                ? DesktopTokens.cardHover
                : DesktopTokens.cardRaised,
            borderRadius: BorderRadius.circular(DesktopTokens.innerRadius),
            border: Border.all(
              color: _hovered
                  ? GlukColors.violet.withOpacity(0.45)
                  : DesktopTokens.cardBorder,
            ),
          ),
          child: Row(
            children: <Widget>[
              FlagCircle(flag: widget.flag ?? '🌐', size: 28),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: GlukColors.text0,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    if (widget.subtitle != null &&
                        widget.subtitle!.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: GlukColors.text2,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.pingMs != null) ...<Widget>[
                Text(
                  formatPing(widget.pingMs!),
                  style: const TextStyle(
                    color: GlukColors.text1,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 12),
              ],
              if (widget.locked)
                const Icon(
                  Icons.lock_outline_rounded,
                  size: 15,
                  color: GlukColors.text2,
                )
              else
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dot,
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: dot.withOpacity(0.6),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
              const SizedBox(width: 12),
              AnimatedRotation(
                duration: const Duration(milliseconds: 160),
                turns: _hovered ? 0.02 : 0,
                child: const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: GlukColors.text1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

