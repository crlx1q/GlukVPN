import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../theme/tokens.dart';
import '../../widgets/logo.dart';

/// Custom frameless title bar.
///
/// The native Windows chrome does not fit the deep-black glass look, so the
/// window is created without a frame and this bar provides dragging and the
/// caption buttons.
///
/// The close button intentionally routes through the normal close path, which
/// [WindowController] intercepts to hide to tray instead of quitting.
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({
    super.key,
    this.height = 44,
    this.showMaximize = true,
    this.title = 'GlukVPN',
    this.trailing,
  });

  final double height;
  final bool showMaximize;
  final String title;
  final Widget? trailing;

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
              child: Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Row(
                  children: <Widget>[
                    const GlukLogo(size: 20, radius: 6),
                    const SizedBox(width: 10),
                    Text(
                      title,
                      style: const TextStyle(
                        color: GlukColors.text1,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ],
                ),
              ),
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
            // setPreventClose(true) turns this into onWindowClose, which the
            // WindowController handles by hiding. The VPN keeps running.
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
    final background = !_hovered
        ? Colors.transparent
        : (widget.danger
            ? GlukColors.danger.withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: 0.08));

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
            width: 46,
            height: double.infinity,
            color: background,
            child: Icon(
              widget.icon,
              size: 16,
              color: _hovered && widget.danger
                  ? Colors.white
                  : GlukColors.text1,
            ),
          ),
        ),
      ),
    );
  }
}
