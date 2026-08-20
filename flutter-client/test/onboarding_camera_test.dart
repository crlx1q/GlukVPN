import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/screens/onboarding_screen.dart';
import 'package:glukvpn/utils/geo.dart';

/// Onboarding is one camera moving over one planet. That choreography is plain
/// data ([IntroCamera]), so it can be checked without pumping a frame.
void main() {
  // Roughly Kokshetau and Frankfurt - the two places this build actually joins.
  final MapPoint self = projectLatLon(53.28, 69.39);
  final MapPoint server = projectLatLon(50.11, 8.68);
  final IntroCamera camera = IntroCamera(self: self, server: server);

  /// At `zoom`, the sphere's diameter is `width * zoom / pi`, so a shot fits
  /// the screen's width only while zoom stays under pi.
  const double fitsTheScreen = math.pi;

  group('the three beats', () {
    test('open wide, then close in twice', () {
      final List<IntroFrame> frames = camera.frames;
      expect(frames, hasLength(3));
      expect(frames[0].zoom, lessThan(frames[1].zoom));
      expect(frames[1].zoom, lessThan(frames[2].zoom));
    });

    test('the first frame shows the whole globe, a little below centre', () {
      final IntroFrame frame = camera.frames.first;
      expect(frame.zoom, lessThan(fitsTheScreen));
      expect(frame.anchor.dx, closeTo(0.5, 0.02));
      expect(frame.anchor.dy, greaterThan(0.5));
    });

    test('the second frame looks straight at the user', () {
      final IntroFrame frame = camera.frames[1];
      expect(frame.longitude, closeTo(IntroCamera.longitudeOf(self), 1e-9));
      expect(frame.latitude, closeTo(IntroCamera.latitudeOf(self), 1e-9));
    });

    test('the last frame overflows the screen and sits off to the left', () {
      final IntroFrame frame = camera.frames.last;
      // Too close to fit: the planet runs off the edges on purpose.
      expect(frame.zoom, greaterThan(fitsTheScreen));
      // Middle of the sphere pushed left, so its right half fills the screen.
      expect(frame.anchor.dx, lessThan(0.4));
      // The node still has to be in shot, not parked behind the left edge.
      final double delta =
          ((IntroCamera.longitudeOf(server) - frame.longitude + 540) % 360) -
              180;
      expect(delta.abs(), lessThan(25));
    });
  });

  group('the move between beats', () {
    test('lands exactly on each frame at each stop', () {
      for (int i = 0; i < camera.frames.length; i++) {
        expect(
          camera.at(i.toDouble()).zoom,
          closeTo(camera.frames[i].zoom, 1e-9),
        );
        expect(
          camera.at(i.toDouble()).longitude,
          closeTo(camera.frames[i].longitude, 1e-9),
        );
      }
    });

    test('flies instead of ramping: it pulls back mid-flight', () {
      final double midway = camera.at(0.5).zoom;
      final double straightLine =
          (camera.frames[0].zoom + camera.frames[1].zoom) / 2;
      expect(midway, lessThan(straightLine));
    });

    test('clamps outside the page range instead of overshooting', () {
      expect(camera.at(-3).zoom, closeTo(camera.frames.first.zoom, 1e-9));
      expect(camera.at(9).zoom, closeTo(camera.frames.last.zoom, 1e-9));
    });

    test('longitudes take the short way round the date line', () {
      expect(IntroFrame.lerpLongitude(170, -170, 0.5), closeTo(180, 1e-9));
      expect(IntroFrame.lerpLongitude(-170, 170, 0.5), closeTo(-180, 1e-9));
      expect(IntroFrame.lerpLongitude(10, 40, 0.5), closeTo(25, 1e-9));
    });
  });

  group('what appears when', () {
    test('the user marker fades in on the way to beat two', () {
      expect(camera.selfOpacity(0), 0);
      expect(camera.selfOpacity(0.6), greaterThan(0));
      expect(camera.selfOpacity(1), 1);
    });

    test('the node marker waits for beat three', () {
      expect(camera.serverOpacity(1), 0);
      expect(camera.serverOpacity(2), 1);
    });

    test('the route draws itself last, after both ends exist', () {
      expect(camera.routeProgress(1.5), 0);
      expect(camera.routeProgress(2), 1);
      expect(camera.serverOpacity(1.8), greaterThan(0));
    });
  });
}
