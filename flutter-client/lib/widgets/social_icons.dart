import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/tokens.dart';

/// Google and Telegram marks, rendered from the official SVG artwork.
///
/// ROUND 6: these used to be `CustomPainter` reconstructions. That was the
/// wrong call. A brand mark is either the real artwork or a visible fake, and
/// the hand-drawn Google "G" had the wrong arc weights while the Telegram plane
/// had the wrong fold geometry - both read as "almost right", which is worse
/// than obviously wrong.
///
/// The real files now live in `assets/brands/` and are drawn by `flutter_svg`,
/// which is pure Dart. No native plugin is added to either the Android or the
/// Windows build, so this is safe to share between both pubspecs.
class GoogleMark extends StatelessWidget {
  const GoogleMark({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
        'assets/brands/google.svg',
        width: size,
        height: size,
        // Deliberately no colour filter: the mark carries its own four brand
        // colours and tinting it would break Google's brand rules.
        semanticsLabel: 'Google',
      );
}

/// The Telegram roundel: official blue gradient plus the white paper plane.
class TelegramMark extends StatelessWidget {
  const TelegramMark({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
        'assets/brands/telegram.svg',
        width: size,
        height: size,
        semanticsLabel: 'Telegram',
      );
}

/// Round glass button that carries one of the marks above.
class SocialSignInButton extends StatelessWidget {
  const SocialSignInButton({
    super.key,
    required this.child,
    required this.onTap,
    this.semanticLabel,
    this.size = 54,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: GlukColors.glass,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(size / 2),
          side: BorderSide(color: GlukColors.stroke),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
