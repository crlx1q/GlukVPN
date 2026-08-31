import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../theme/tokens.dart';

/// Frameless-window caption strip.
///
/// Redesigned to be invisible furniture: the logo and wordmark now live in the
/// sidebar (as in the approved reference), so this bar only provides the drag
/// region and the three caption buttons floating over the page background.
///
/// The close button routes through the normal close path, which
/// [WindowController] intercepts to hide to tray instead of quitting, so the
/// tunnel survives closing the window.
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({
    super.key,
    this.height = 40,
    this.showMaximize = true,
    this.title = 'GlukVPN',
    this.trailing,
    this.showTitle = false,
  });

  final double height;
  final bool showMaximize;
  final String title;
  final Widget? trailing;

  /// Only the mini panel needs a caption label; the main window gets it from
  /// the sidebar wordmark.
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Row(
        children: <Widget>[
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: () async {
                if (!showMaximize) return;
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
              child: showTitle
                  ? Padding(
                      padding: const EdgeInsets.only(left: 14),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          title,
                          style: const TextStyle(
                            color: GlukColors.text2,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.expand(),
            ),
          ),
          if (trailing != null) trailing!,
          _CaptionButton(
            icon: Icons.remove_rounded,
            tooltip: 'Minimize',
            onTap: () => windowManager.minimize(),
          ),
          if (showMaximize)
            _CaptionButton(
              icon: Icons.crop_square_rounded,
              tooltip: 'Maximize',
              onTap: () async {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
            ),
          _CaptionButton(
            icon: Icons.close_rounded,
            tooltip: 'Hide to tray',
            danger: true,
            onTap: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.danger = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final bool danger;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color background = !_hovered
        ? Colors.transparent
        : (widget.danger
            ? GlukColors.danger.withOpacity(0.85)
            : Colors.white.withOpacity(0.08));

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 44,
            height: double.infinity,
            color: background,
            child: Icon(
              widget.icon,
              size: 15,
              color: _hovered && widget.danger
                  ? Colors.white
                  : GlukColors.text2,
            ),
          ),
        ),
      ),
    );
  }
}
