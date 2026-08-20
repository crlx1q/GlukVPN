import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/data/world_map_data.dart';
import 'package:glukvpn/utils/geo.dart';

/// Guards the two pieces of the redesign that are data, not looks: the dotted
/// world map transcribed from the mock-up, and the projection that puts the
/// "you" and "server" markers on it.
void main() {
  group('world map data', () {
    test('carries every dot of the mock-up map', () {
      expect(worldMapDotCount, 3065);
      expect(worldMapDots, hasLength(worldMapDotCount));
    });

    test('reproduces the lattice the mock-up drew', () {
      expect(worldMapCols, 237);
      expect(worldMapRows, 69);
      expect(worldMapOriginX, 0.5);
      expect(worldMapStepX, 0.5);
      expect(worldMapDotRadius, 0.4);
      expect(worldMapStepY, closeTo(math.sqrt(3) / 2, 1e-9));
    });

    test('every dot sits on the lattice and inside the viewBox', () {
      for (final MapPoint dot in worldMapDots) {
        final double col = (dot.x - worldMapOriginX) / worldMapStepX;
        final double row = dot.y / worldMapStepY;
        expect(col, closeTo(col.roundToDouble(), 1e-6));
        expect(row, closeTo(row.roundToDouble(), 1e-6));
        expect(dot.x, inInclusiveRange(0, mapWidth));
        expect(dot.y, inInclusiveRange(0, mapHeight));
      }
    });

    test('spans both hemispheres, so no continent was lost in transcription', () {
      final double minX = worldMapDots.map((MapPoint d) => d.x).reduce(math.min);
      final double maxX = worldMapDots.map((MapPoint d) => d.x).reduce(math.max);
      final double maxY = worldMapDots.map((MapPoint d) => d.y).reduce(math.max);
      expect(minX, lessThan(mapWidth * 0.1));
      expect(maxX, greaterThan(mapWidth * 0.9));
      expect(maxY, closeTo(58.89, 0.02));
    });
  });

  group('projectLatLon', () {
    test('lands on the coordinates the mock-up hard-coded for Germany', () {
      final MapPoint frankfurt = projectLatLon(50.11, 8.68);
      expect(frankfurt.x, closeTo(62.37, 0.02));
      expect(frankfurt.y, closeTo(13.30, 0.02));
    });

    test('maps the corners of the equirectangular projection', () {
      final MapPoint topLeft = projectLatLon(90, -180);
      final MapPoint bottomRight = projectLatLon(-90, 180);
      expect(topLeft.x, closeTo(0, 1e-9));
      expect(topLeft.y, closeTo(0, 1e-9));
      expect(bottomRight.x, closeTo(mapWidth, 1e-9));
      expect(bottomRight.y, closeTo(mapHeight, 1e-9));
    });

    test('clamps out-of-range input instead of drawing off-map', () {
      expect(projectLatLon(120, 400).x, closeTo(mapWidth, 1e-9));
      expect(projectLatLon(120, 400).y, closeTo(0, 1e-9));
    });
  });

  group('countryPoint / countryFlag', () {
    test('resolves a node country to a plottable point', () {
      final MapPoint? germany = countryPoint('DE');
      expect(germany, isNotNull);
      expect(germany!.x, closeTo(62.37, 0.02));
      expect(countryPoint('de')?.x, closeTo(germany.x, 1e-9));
    });

    test('returns null for countries the map table does not know', () {
      expect(countryPoint(null), isNull);
      expect(countryPoint(''), isNull);
      expect(countryPoint('ZZ'), isNull);
    });

    test('uses the flag from the country table', () {
      expect(countryFlag('DE'), '\u{1F1E9}\u{1F1EA}');
      expect(countryFlag('US'), '\u{1F1FA}\u{1F1F8}');
    });
  });

  group('approximateSelfLocation', () {
    test('reads the region out of the device locale', () {
      final SelfLocation self =
          approximateSelfLocation(localeOverride: 'de_DE.UTF-8');
      expect(self.precision, 'country');
      expect(self.countryCode, 'DE');
      expect(self.label, 'Germany');
      expect(self.point.x, closeTo(62.37, 0.02));
    });

    test('falls back to the UTC offset without asking for a location', () {
      final SelfLocation self = approximateSelfLocation(
        localeOverride: 'C',
        utcOffsetOverride: const Duration(hours: 5),
      );
      expect(self.precision, 'timezone');
      expect(self.countryCode, isNull);
      expect(self.label, 'Your location');
      // 5h east of UTC is longitude 75, and x depends only on longitude.
      expect(self.point.x, closeTo(projectLatLon(0, 75).x, 1e-9));
    });
  });

  group('ConnectionArc', () {
    test('bows the cable above both endpoints like the mock-up path', () {
      const ConnectionArc arc = ConnectionArc(
        from: MapPoint(82.44, 12.24),
        to: MapPoint(62.37, 13.30),
      );

      expect(arc.control.x, closeTo(72.405, 1e-6));
      expect(arc.control.y, closeTo(3.24, 1e-6));

      expect(arc.pointAt(0).x, closeTo(82.44, 1e-6));
      expect(arc.pointAt(0).y, closeTo(12.24, 1e-6));
      expect(arc.pointAt(1).x, closeTo(62.37, 1e-6));
      expect(arc.pointAt(1).y, closeTo(13.30, 1e-6));

      // The midpoint must sit above (smaller y than) both ends.
      expect(arc.pointAt(0.5).y, lessThan(12.24));
    });
  });
}
