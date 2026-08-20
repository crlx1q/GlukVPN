import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../utils/signal.dart';

/// Signal strength drawn the way a phone draws it: three upright bars on one
/// geometric system, rising left to right.
///
/// It is a level, not a readout - the round-trip in milliseconds belongs in the
/// row's detail line, never inside this element. Bars are lit from the value
/// [signalStrengthFor] computes out of ping, node load and online state, so a
/// server never gets three bars for being in a nice country.
class SignalBars extends StatelessWidget {
  const SignalBars({
    super.key,
    required this.strength,
    this.height = 15,
    this.barWidth = 3.5,
    this.gap = 3,
  });

  final SignalStrength strength;

  /// Height of the tallest bar.
  final double height;
  final double barWidth;
  final double gap;

  /// green = excellent, amber = medium, red = bad, grey = offline.
  Color get tone {
    switch (strength) {
      case SignalStrength.strong:
        return GlukColors.connected;
      case SignalStrength.fair:
        return GlukColors.amber;
      case SignalStrength.weak:
        return GlukColors.danger;
      case SignalStrength.offline:
        return GlukColors.text2;
    }
  }

  @override
  Widget build(BuildContext context) {
    final double width = barWidth * 3 + gap * 2;
    return Semantics(
      label: strength.label,
      child: CustomPaint(
        size: Size(width, height),
        painter: _BarsPainter(
          bars: strength.bars,
          tone: tone,
          barWidth: barWidth,
          gap: gap,
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  const _BarsPainter({
    required this.bars,
    required this.tone,
    required this.barWidth,
    required this.gap,
  });

  final int bars;
  final Color tone;
  final double barWidth;
  final double gap;

  /// Each bar is a fraction of the tallest one. Equal steps, so the shape reads
  /// as a scale rather than as decoration.
  static const List<double> _steps = <double>[0.46, 0.73, 1.0];

  @override
  void paint(Canvas canvas, Size size) {
    final Radius radius = Radius.circular(barWidth * 0.4);
    for (int i = 0; i < _steps.length; i++) {
      final double barHeight = size.height * _steps[i];
      final double left = i * (barWidth + gap);
      final RRect bar = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, size.height - barHeight, barWidth, barHeight),
        radius,
      );
      final bool lit = i < bars;
      canvas.drawRRect(
        bar,
        Paint()
          ..isAntiAlias = true
          ..color = lit ? tone : Colors.white.withOpacity(0.13),
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.bars != bars ||
      old.tone != tone ||
      old.barWidth != barWidth ||
      old.gap != gap;
}
