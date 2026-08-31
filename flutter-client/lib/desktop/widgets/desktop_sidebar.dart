import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../widgets/logo.dart';
import '../theme/desktop_theme.dart';

/// One navigation entry.
class SidebarItem {
  const SidebarItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// Left navigation column: wordmark, tall nav pills, account card.
///
/// Replaces the first attempt's narrow 84 px icon rail, which left the window
/// looking like a stretched phone. This is the layout from the approved
/// desktop reference: readable labels, generous hit targets, and the account
/// anchored at the bottom.
class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
    required this.userName,
    this.userIdLabel,
    this.onAccountTap,
    this.statusColor,
    this.width = DesktopTokens.sidebarWidth,
  });

  final List<SidebarItem> items;
  final int index;
  final ValueChanged<int> onChanged;

  final String userName;
  final String? userIdLabel;
  final VoidCallback? onAccountTap;

  /// Small tunnel indicator drawn on the avatar ring.
  final Color? statusColor;

  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      decoration: const BoxDecoration(color: DesktopTokens.sidebar),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Row(
              children: <Widget>[
                const GlukLogo(size: 42, radius: 13),
                const SizedBox(width: 12),
                Text(
                  'GlukVPN',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          for (int i = 0; i < items.length; i++)
            _NavPill(
              item: items[i],
              selected: i == index,
              onTap: () => onChanged(i),
            ),
          const Spacer(),
          _AccountCard(
            name: userName,
            idLabel: userIdLabel,
            statusColor: statusColor,
            onTap: onAccountTap,
          ),
        ],
      ),
    );
  }
}

class _NavPill extends StatefulWidget {
  const _NavPill({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final SidebarItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavPill> createState() => _NavPillState();
}

class _NavPillState extends State<_NavPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool selected = widget.selected;
    final Color tint = selected
        ? Colors.white
        : (_hovered ? GlukColors.text0 : GlukColors.text1);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          height: 52,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(DesktopTokens.innerRadius),
            gradient: selected
                ? LinearGradient(
                    colors: <Color>[
                      GlukColors.violet.withOpacity(0.34),
                      GlukColors.violet.withOpacity(0.12),
                    ],
                  )
                : null,
            color: selected
                ? null
                : (_hovered
                    ? Colors.white.withOpacity(0.045)
                    : Colors.transparent),
            border: Border.all(
              color: selected
                  ? GlukColors.violet.withOpacity(0.55)
                  : Colors.transparent,
            ),
            boxShadow: selected
                ? <BoxShadow>[
                    BoxShadow(
                      color: GlukColors.violet.withOpacity(0.22),
                      blurRadius: 18,
                      spreadRadius: -4,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: <Widget>[
              Icon(widget.item.icon, size: 20, color: tint),
              const SizedBox(width: 13),
              Expanded(
                child: Text(
                  widget.item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tint,
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom-left account chip: avatar, display name, public ID.
class _AccountCard extends StatefulWidget {
  const _AccountCard({
    required this.name,
    this.idLabel,
    this.statusColor,
    this.onTap,
  });

  final String name;
  final String? idLabel;
  final Color? statusColor;
  final VoidCallback? onTap;

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  bool _hovered = false;

  String get _initial {
    final String trimmed = widget.name.trim();
    if (trimmed.isEmpty) return 'G';
    return trimmed.substring(0, 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: _hovered
                ? DesktopTokens.cardHover
                : DesktopTokens.cardRaised,
            borderRadius: BorderRadius.circular(DesktopTokens.innerRadius),
            border: Border.all(color: DesktopTokens.cardBorder),
          ),
          child: Row(
            children: <Widget>[
              Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: <Color>[
                          GlukColors.violet.withOpacity(0.85),
                          GlukColors.indigo.withOpacity(0.85),
                        ],
                      ),
                    ),
                    child: Text(
                      _initial,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                  if (widget.statusColor != null)
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.statusColor,
                          border: Border.all(
                            color: DesktopTokens.cardRaised,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: GlukColors.text0,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    if (widget.idLabel != null &&
                        widget.idLabel!.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 1),
                      Text(
                        widget.idLabel!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: GlukColors.text2,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
