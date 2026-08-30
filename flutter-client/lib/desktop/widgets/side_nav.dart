import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// One entry in the desktop rail.
class SideNavItem {
  const SideNavItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// Vertical navigation rail.
///
/// Desktop gets a rail rather than the mobile bottom bar (requirement 5: do
/// not just stretch the Android layout). Same glass + violet language.
class SideNav extends StatelessWidget {
  const SideNav({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
    this.footer,
    this.width = 84,
  });

  final List<SideNavItem> items;
  final int index;
  final ValueChanged<int> onChanged;
  final Widget? footer;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: GlukColors.navbar,
        border: Border(
          right: BorderSide(color: GlukColors.stroke, width: 1),
        ),
      ),
      child: Column(
        children: <Widget>[
          const SizedBox(height: 18),
          for (var i = 0; i < items.length; i++)
            _NavButton(
              item: items[i],
              selected: i == index,
              onTap: () => onChanged(i),
            ),
          const Spacer(),
          if (footer != null) ...<Widget>[
            footer!,
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

class _NavButton extends StatefulWidget {
  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final SideNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final tint = selected
        ? GlukColors.violetLight
        : (_hovered ? GlukColors.text0 : GlukColors.text2);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: GlukMotion.screen,
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: selected
                ? GlukColors.violet.withOpacity(0.16)
                : (_hovered
                    ? Colors.white.withOpacity(0.04)
                    : Colors.transparent),
            border: Border.all(
              color: selected
                  ? GlukColors.violet.withOpacity(0.45)
                  : Colors.transparent,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(widget.item.icon, size: 20, color: tint),
              const SizedBox(height: 6),
              Text(
                widget.item.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tint,
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
