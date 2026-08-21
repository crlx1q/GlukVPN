import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/utils/blob.dart';

/// The connect button's background used to flash small crosses along its edges
/// while morphing. These tests pin down the geometry that makes that
/// impossible: radii are normalised the way CSS does it, so neighbouring arcs
/// always meet tangentially, the outline never leaves its box, and the
/// silhouette changes smoothly from frame to frame.
void main() {
  // The two keyframes that produced the artefact: 0.65 + 0.35 is exactly one
  // full edge, and anything interpolated near it used to overshoot.
  const List<double> spikyH = <double>[0.42, 0.58, 0.65, 0.35];
  const List<double> spikyV = <double>[0.45, 0.40, 0.60, 0.55];
  const Size box = Size(210, 210);

  group('blobRadiiScale', () {
    test('leaves radii that already fit untouched', () {
      expect(
        blobRadiiScale(
          h: const <double>[0.3, 0.3, 0.3, 0.3],
          v: const <double>[0.3, 0.3, 0.3, 0.3],
          width: 210,
          height: 210,
        ),
        1,
      );
    });

    test('accepts an edge that is filled exactly', () {
      // 0.42 + 0.58 == 1.0: allowed, the straight part is simply zero long.
      expect(
        blobRadiiScale(h: spikyH, v: spikyV, width: 210, height: 210),
        closeTo(1, 1e-9),
      );
    });

    test('scales every radius by one factor when an edge overflows', () {
      // Top edge asks for 120% of the width.
      final double factor = blobRadiiScale(
        h: const <double>[0.7, 0.5, 0.3, 0.3],
        v: const <double>[0.3, 0.3, 0.3, 0.3],
        width: 200,
        height: 200,
      );
      expect(factor, closeTo(1 / 1.2, 1e-9));
    });

    test('checks vertical edges as well as horizontal ones', () {
      final double factor = blobRadiiScale(
        h: const <double>[0.2, 0.2, 0.2, 0.2],
        v: const <double>[0.9, 0.2, 0.2, 0.9],
        width: 100,
        height: 100,
      );
      // Left edge: 0.9 + 0.9 = 1.8 of the height.
      expect(factor, closeTo(1 / 1.8, 1e-9));
    });
  });

  group('blobPath', () {
    test('stays inside its box on the keyframe that used to spike', () {
      final Rect bounds = blobPath(size: box, h: spikyH, v: spikyV).getBounds();
      expect(bounds.left, greaterThanOrEqualTo(-0.01));
      expect(bounds.top, greaterThanOrEqualTo(-0.01));
      expect(bounds.right, lessThanOrEqualTo(box.width + 0.01));
      expect(bounds.bottom, lessThanOrEqualTo(box.height + 0.01));
    });

    test('stays inside its box even when the radii are impossible', () {
      final Rect bounds = blobPath(
        size: box,
        h: const <double>[0.95, 0.95, 0.95, 0.95],
        v: const <double>[0.95, 0.95, 0.95, 0.95],
      ).getBounds();
      expect(bounds.left, greaterThanOrEqualTo(-0.01));
      expect(bounds.right, lessThanOrEqualTo(box.width + 0.01));
      expect(bounds.top, greaterThanOrEqualTo(-0.01));
      expect(bounds.bottom, lessThanOrEqualTo(box.height + 0.01));
    });

    test('is a single closed contour', () {
      final Path path = blobPath(size: box, h: spikyH, v: spikyV);
      expect(path.computeMetrics().length, 1);
      expect(path.computeMetrics().first.isClosed, isTrue);
    });

    test('an empty box produces an empty path instead of throwing', () {
      expect(
        blobPath(size: Size.zero, h: spikyH, v: spikyV).computeMetrics().isEmpty,
        isTrue,
      );
    });
  });

  group('blobReach', () {
    test('never exceeds the half-diagonal of the box', () {
      final double reach = blobReach(size: box, h: spikyH, v: spikyV);
      final double halfDiagonal =
          Offset(box.width / 2, box.height / 2).distance;
      expect(reach, lessThanOrEqualTo(halfDiagonal + 0.01));
      // And it is a real shape, not a point.
      expect(reach, greaterThan(box.width * 0.3));
    });

    test('changes smoothly across a morph', () {
      // The artefact was a one-frame jump in the outline. Walking the morph in
      // small steps, the extreme radius must never jump.
      const BlobShape from = BlobShape(h: spikyH, v: spikyV);
      const BlobShape to = BlobShape(
        h: <double>[0.60, 0.40, 0.45, 0.55],
        v: <double>[0.55, 0.65, 0.35, 0.45],
        rotation: 8,
        scale: 1.02,
      );

      double? previous;
      for (int step = 0; step <= 120; step++) {
        final BlobShape shape = BlobShape.lerp(from, to, step / 120);
        final double reach = blobReach(size: box, h: shape.h, v: shape.v);
        if (previous != null) {
          expect(
            (reach - previous).abs(),
            lessThan(1.5),
            reason: 'discontinuity at step $step',
          );
        }
        previous = reach;
      }
    });
  });

  group('BlobShape.lerp', () {
    test('interpolates radii, rotation and scale', () {
      const BlobShape a = BlobShape(
        h: <double>[0.1, 0.2, 0.3, 0.4],
        v: <double>[0.4, 0.3, 0.2, 0.1],
      );
      const BlobShape b = BlobShape(
        h: <double>[0.3, 0.4, 0.5, 0.6],
        v: <double>[0.6, 0.5, 0.4, 0.3],
        rotation: -10,
        scale: 1.14,
      );

      final BlobShape mid = BlobShape.lerp(a, b, 0.5);
      for (int i = 0; i < mid.h.length; i++) {
        expect(mid.h[i], closeTo(<double>[0.2, 0.3, 0.4, 0.5][i], 1e-9));
      }
      for (int i = 0; i < mid.v.length; i++) {
        expect(mid.v[i], closeTo(<double>[0.5, 0.4, 0.3, 0.2][i], 1e-9));
      }
      expect(mid.rotation, closeTo(-5, 1e-9));
      expect(mid.scale, closeTo(1.07, 1e-9));

      final BlobShape start = BlobShape.lerp(a, b, 0);
      expect(start.h, a.h);
      expect(start.scale, a.scale);
    });
  });
}
