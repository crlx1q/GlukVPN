import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The GlukVPN mark.
///
/// This renders `assets/logo.png` - the file you drop in yourself. Nothing is
/// drawn or generated here; the only painted thing is a plain violet tile used
/// if the asset is missing, so a forgotten file shows as a neutral placeholder
/// instead of crashing the screen.
class GlukLogo extends StatelessWidget {
  const GlukLogo({
    super.key,
    this.size = 56,
    this.radius,
    this.glow = true,
  });

  final double size;

  /// Corner radius of the tile. Defaults to the token used across the app.
  final double? radius;

  /// Soft violet halo behind the mark, as on the splash and the login card.
  final bool glow;

  static const String assetPath = 'assets/logo.png';

  @override
  Widget build(BuildContext context) {
    final double corner = radius ?? size * (GlukSizes.logoRadius / 56);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(corner),
        boxShadow: glow
            ? <BoxShadow>[
                BoxShadow(
                  color: GlukColors.violet.withOpacity(0.28),
                  blurRadius: size * 0.5,
                  spreadRadius: size * 0.02,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(corner),
        child: Image.asset(
          assetPath,
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          errorBuilder: (BuildContext context, Object error, StackTrace? stack) {
            return const _MissingLogoTile();
          },
        ),
      ),
    );
  }
}

/// Shown only when `assets/logo.png` is absent from the bundle.
class _MissingLogoTile extends StatelessWidget {
  const _MissingLogoTile();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[GlukColors.violet, GlukColors.indigo],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}
