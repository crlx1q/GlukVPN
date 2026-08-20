import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// One destination in [GlukNavBar].
class GlukNavItem {
  const GlukNavItem({required this.icon, required this.activeIcon, required this.label});

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

/// `.navbar` from the mock-up: a floating frosted pill, 18 px radius, with a
/// small rounded chip behind the active icon (34x24, `rgba(124,92,246,0.16)`)
/// and 9.5 px labels underneath.
///
/// Not a Material NavigationBar: that one owns its own height, indicator shape
/// and elevation, none of which match the design.
class GlukNavBar extends StatelessWidget {
  const GlukNavBar({
    super.key,
    required this.index,
    required this.onChanged,
    required this.items,
  });

  final int index;
  final ValueChanged<int> onChanged;
  final List<GlukNavItem> items;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final BorderRadius shape = BorderRadius.circular(GlukSizes.navRadius);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: GlukColors.navbar,
              borderRadius: shape,
              border: Border.all(color: Colors.white.withOpacity(0.07)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List<Widget>.generate(items.length, (int i) {
                  final GlukNavItem item = items[i];
                  final bool active = i == index;
                  return Semantics(
                    button: true,
                    selected: active,
                    label: item.label,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: active ? null : () => onChanged(i),
                      child: SizedBox(
                        width: 64,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: 34,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: active
                                    ? GlukColors.violet.withOpacity(0.16)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Icon(
                                active ? item.activeIcon : item.icon,
                                size: 18,
                                color: active
                                    ? GlukColors.violetLight
                                    : GlukColors.text2,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              item.label,
                              style: text.bodySmall?.copyWith(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w600,
                                color: active
                                    ? GlukColors.violetLight
                                    : GlukColors.text2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
