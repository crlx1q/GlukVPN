import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../theme/desktop_theme.dart';

/// Wide reassurance strip along the bottom of the home screen.
///
/// Doubles as the problem surface: when the client has something to say (the
/// tunnel service is missing, the node list failed to load, the session
/// expired) the same strip turns amber or red and offers a single action,
/// instead of the state being invisible the way it was in the first build.
class SecureBanner extends StatelessWidget {
  const SecureBanner({
    super.key,
    required this.title,
    required this.subtitle,
    this.tone = SecureTone.idle,
    this.actionLabel,
    this.onAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
  });

  final String title;
  final String subtitle;
  final SecureTone tone;

  final String? actionLabel;
  final VoidCallback? onAction;

  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

  Color get _accent {
    switch (tone) {
      case SecureTone.secure:
        return GlukColors.connected;
      case SecureTone.warning:
        return GlukColors.amber;
      case SecureTone.danger:
        return GlukColors.danger;
      case SecureTone.idle:
        return GlukColors.violetLight;
    }
  }

  IconData get _icon {
    switch (tone) {
      case SecureTone.secure:
        return Icons.shield_rounded;
      case SecureTone.warning:
        return Icons.warning_amber_rounded;
      case SecureTone.danger:
        return Icons.error_outline_rounded;
      case SecureTone.idle:
        return Icons.shield_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = _accent;

    return AnimatedContainer(
      duration: GlukMotion.screen,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: DesktopTokens.cardDecoration(
        color: tone == SecureTone.idle
            ? DesktopTokens.card
            : Color.alphaBlend(accent.withOpacity(0.07), DesktopTokens.card),
        borderColor: tone == SecureTone.idle
            ? DesktopTokens.cardBorder
            : accent.withOpacity(0.30),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(_icon, size: 17, color: accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GlukColors.text0,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GlukColors.text1,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
          if (secondaryActionLabel != null && onSecondaryAction != null)
            ...<Widget>[
            const SizedBox(width: 12),
            _BannerButton(
              label: secondaryActionLabel!,
              accent: GlukColors.text1,
              onTap: onSecondaryAction!,
              subtle: true,
            ),
          ],
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(width: 10),
            _BannerButton(
              label: actionLabel!,
              accent: accent,
              onTap: onAction!,
            ),
          ],
          if (actionLabel == null && tone == SecureTone.secure) ...<Widget>[
            const SizedBox(width: 12),
            Icon(
              Icons.verified_user_rounded,
              size: 20,
              color: accent.withOpacity(0.85),
            ),
          ],
        ],
      ),
    );
  }
}

enum SecureTone { idle, secure, warning, danger }

class _BannerButton extends StatefulWidget {
  const _BannerButton({
    required this.label,
    required this.accent,
    required this.onTap,
    this.subtle = false,
  });

  final String label;
  final Color accent;
  final VoidCallback onTap;
  final bool subtle;

  @override
  State<_BannerButton> createState() => _BannerButtonState();
}

class _BannerButtonState extends State<_BannerButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: widget.subtle
                ? (_hovered
                    ? Colors.white.withOpacity(0.07)
                    : Colors.transparent)
                : widget.accent.withOpacity(_hovered ? 0.26 : 0.16),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.subtle
                  ? DesktopTokens.cardBorder
                  : widget.accent.withOpacity(0.45),
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: widget.subtle ? GlukColors.text1 : widget.accent,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}
