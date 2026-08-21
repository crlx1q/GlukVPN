import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The page backdrop from the mock-up's background study: `#05040a` with four
/// very dark violet wave bands over it and two hairlines between them.
///
/// It replaces the flat black behind every screen. Nothing here moves and
/// nothing blurs - it is six filled paths, drawn once per size change, so it
/// costs nothing on a phone and never competes with the map or the button.
///
/// Geometry is the mock-up's SVG verbatim: a 800x800 viewBox with
/// `preserveAspectRatio="xMidYMid slice"`, i.e. scaled to cover and centred.
class PageBackground extends StatelessWidget {
  const PageBackground({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: GlukColors.pageBg,
      child: Stack(
        children: <Widget>[
          const Positioned.fill(
            child: RepaintBoundary(
              child: IgnorePointer(
                child: CustomPaint(painter: WavesPainter(), size: Size.infinite),
              ),
            ),
          ),
          if (child != null) Positioned.fill(child: child!),
        ],
      ),
    );
  }
}

/// The wave bands. Public so a test can assert the geometry is still the
/// mock-up's and did not drift into decoration.
class WavesPainter extends CustomPainter {
  const WavesPainter();

  /// The mock-up's `viewBox="0 0 800 800"`.
  static const double viewBox = 800;

  /// `#wg1`: `linearGradient x1=0 y1=0 x2=1 y2=1`.
  static const Color wave1From = Color(0xFF1A1230);
  static const Color wave1To = Color(0xFF08060F);

  /// `#wg2`: `linearGradient x1=0 y1=1 x2=1 y2=0`.
  static const Color wave2From = Color(0xFF140E24);
  static const Color wave2To = Color(0xFF050409);

  /// The two hairlines.
  static const Color line = Color(0xFF241A3A);

  /// Band fills, in the mock-up's order: `[path, gradient index, opacity]`.
  static List<Path> bands() => <Path>[
        // M-50,150 C150,80 300,220 500,140 C650,80 750,180 850,120 L850,-50 L-50,-50 Z
        Path()
          ..moveTo(-50, 150)
          ..cubicTo(150, 80, 300, 220, 500, 140)
          ..cubicTo(650, 80, 750, 180, 850, 120)
          ..lineTo(850, -50)
          ..lineTo(-50, -50)
          ..close(),
        // M-50,320 C120,260 260,380 460,300 C640,230 760,340 850,280 L850,150
        //   C650,220 500,120 350,190 C200,260 80,180 -50,240 Z
        Path()
          ..moveTo(-50, 320)
          ..cubicTo(120, 260, 260, 380, 460, 300)
          ..cubicTo(640, 230, 760, 340, 850, 280)
          ..lineTo(850, 150)
          ..cubicTo(650, 220, 500, 120, 350, 190)
          ..cubicTo(200, 260, 80, 180, -50, 240)
          ..close(),
        // M-50,520 C140,440 320,560 520,470 C680,400 780,500 850,450 L850,650
        //   C700,600 600,680 450,630 C280,570 130,650 -50,600 Z
        Path()
          ..moveTo(-50, 520)
          ..cubicTo(140, 440, 320, 560, 520, 470)
          ..cubicTo(680, 400, 780, 500, 850, 450)
          ..lineTo(850, 650)
          ..cubicTo(700, 600, 600, 680, 450, 630)
          ..cubicTo(280, 570, 130, 650, -50, 600)
          ..close(),
        // M-50,750 C160,680 340,800 540,720 C700,660 800,740 850,700 L850,850 L-50,850 Z
        Path()
          ..moveTo(-50, 750)
          ..cubicTo(160, 680, 340, 800, 540, 720)
          ..cubicTo(700, 660, 800, 740, 850, 700)
          ..lineTo(850, 850)
          ..lineTo(-50, 850)
          ..close(),
      ];

  static List<Path> hairlines() => <Path>[
        // M-50,420 C180,380 260,460 480,400 C620,360 700,420 850,380
        Path()
          ..moveTo(-50, 420)
          ..cubicTo(180, 380, 260, 460, 480, 400)
          ..cubicTo(620, 360, 700, 420, 850, 380),
        // M-50,600 C200,560 300,640 520,580 C660,540 740,600 850,560
        Path()
          ..moveTo(-50, 600)
          ..cubicTo(200, 560, 300, 640, 520, 580)
          ..cubicTo(660, 540, 740, 600, 850, 560),
      ];

  /// `slice` means cover: the larger of the two ratios, centred.
  static double coverScale(Size size) =>
      (size.width > size.height ? size.width : size.height) / viewBox;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final double scale = coverScale(size);
    final double dx = (size.width - viewBox * scale) / 2;
    final double dy = (size.height - viewBox * scale) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);

    const List<double> opacities = <double>[0.65, 0.60, 0.55, 0.65];
    final List<Path> paths = bands();

    for (int i = 0; i < paths.length; i++) {
      final Path path = paths[i];
      final Rect box = path.getBounds();
      final bool first = i.isEven; // bands alternate wg1 / wg2
      final double opacity = opacities[i];

      canvas.drawPath(
        path,
        Paint()
          ..isAntiAlias = true
          ..shader = ui.Gradient.linear(
            first ? box.topLeft : box.bottomLeft,
            first ? box.bottomRight : box.topRight,
            <Color>[
              (first ? wave1From : wave2From).withOpacity(opacity),
              (first ? wave1To : wave2To).withOpacity(opacity),
            ],
          ),
      );
    }

    const List<double> lineOpacities = <double>[0.5, 0.4];
    final List<Path> lines = hairlines();
    for (int i = 0; i < lines.length; i++) {
      canvas.drawPath(
        lines[i],
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..isAntiAlias = true
          ..color = line.withOpacity(lineOpacities[i]),
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(WavesPainter oldDelegate) => false;
}
