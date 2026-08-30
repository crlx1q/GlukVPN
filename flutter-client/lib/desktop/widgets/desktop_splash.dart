import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../widgets/logo.dart';

/// Short logo animation shown while the shell wires itself up.
///
/// Requirement 3: this must be *short*. It runs for AppConfig.splashDuration
/// (620 ms) and does not block anything — session restore, server list and
/// subscription all load asynchronously behind it.
class DesktopSplash extends StatefulWidget {
  const DesktopSplash({super.key, this.showProgress = true});

  final bool showProgress;

  @override
  State<DesktopSplash> createState() => _DesktopSplashState();
}

class _DesktopSplashState extends State<DesktopSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();

    _fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.45, curve: Curves.easeOut),
    );
    _scale = Tween<double>(begin: 0.86, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.65, curve: Curves.easeOutBack),
      ),
    );
    _glow = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.25, 1.0, curve: Curves.easeInOut),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: GlukColors.pageBg,
      child: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? child) {
            return Opacity(
              opacity: _fade.value,
              child: Transform.scale(
                scale: _scale.value,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: GlukColors.violet
                                .withValues(alpha: 0.42 * _glow.value),
                            blurRadius: 56 * _glow.value,
                            spreadRadius: 6 * _glow.value,
                          ),
                        ],
                      ),
                      child: const GlukLogo(size: 86, radius: 24),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      'GlukVPN',
                      style: TextStyle(
                        color: GlukColors.text0
                            .withValues(alpha: 0.6 + (_glow.value * 0.4)),
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 3.2,
                      ),
                    ),
                    if (widget.showProgress) ...<Widget>[
                      const SizedBox(height: 26),
                      SizedBox(
                        width: 92,
                        height: 2,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: _glow.value,
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.07),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              GlukColors.violet,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
