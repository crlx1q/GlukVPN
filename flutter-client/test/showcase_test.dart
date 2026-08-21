import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/utils/geo.dart';
import 'package:glukvpn/utils/showcase.dart';

/// The onboarding scene has to look like a working network, not like a
/// two-dot diagram, and it must never "twitch" - no moment where everything
/// resets to show the connection again. Both properties are pure functions of
/// time, so they can be checked without rendering anything.
void main() {
  const ShowcaseWorld world = ShowcaseWorld.standard;

  group('the cast', () {
    test('has several servers and many more people', () {
      expect(world.hubCount, 5);
      expect(world.peerCount, 12);
      expect(world.hubs.length, world.hubCount);
      expect(world.peers.length, world.peerCount);
    });

    test('every point lands inside the map', () {
      for (final MapPoint point in <MapPoint>[...world.hubs, ...world.peers]) {
        expect(point.x, inInclusiveRange(0, mapWidth));
        expect(point.y, inInclusiveRange(0, mapHeight));
        expect(point.fx, inInclusiveRange(0, 1));
        expect(point.fy, inInclusiveRange(0, 1));
      }
    });

    test('the first hub is the node the app actually ships with', () {
      // Frankfurt, so the scene and the server list tell the same story.
      final MapPoint frankfurt = projectLatLon(50.11, 8.68);
      expect(world.hubs.first.x, closeTo(frankfurt.x, 1e-9));
      expect(world.hubs.first.y, closeTo(frankfurt.y, 1e-9));
    });
  });

  group('hubForCycle', () {
    test('always picks a real hub', () {
      for (int peer = 0; peer < world.peerCount; peer++) {
        for (int cycle = 0; cycle < 40; cycle++) {
          expect(world.hubForCycle(peer, cycle), inInclusiveRange(0, world.hubCount - 1));
        }
      }
    });

    test('sends each person somewhere else next time round', () {
      for (int peer = 0; peer < world.peerCount; peer++) {
        for (int cycle = 0; cycle < 10; cycle++) {
          expect(
            world.hubForCycle(peer, cycle),
            isNot(world.hubForCycle(peer, cycle + 1)),
            reason: 'peer $peer would reconnect to the same hub',
          );
        }
      }
    });

    test('is deterministic', () {
      expect(world.hubForCycle(3, 7), world.hubForCycle(3, 7));
    });
  });

  group('threadsAt', () {
    test('never leaves the map empty, and never lights it all up at once', () {
      // Ten minutes of scene, four samples a second.
      int minimum = world.peerCount;
      int maximum = 0;
      for (int step = 0; step <= 2400; step++) {
        final int active = world.activeAt(step * 0.25);
        minimum = active < minimum ? active : minimum;
        maximum = active > maximum ? active : maximum;
      }
      expect(minimum, greaterThanOrEqualTo(4));
      expect(maximum, lessThanOrEqualTo(world.peerCount));
    });

    test('always has at least one established link', () {
      // The scene is designed so that at any moment at least one link is
      // fully established (settled=true), which avoids the "everything
      // resets" feeling. We verify this over 10 minutes at 10 Hz.
      // Brief statistical gaps (< 1 %) are accepted; what matters is that
      // the vast majority of frames show something settled.
      int settled = 0;
      const int total = 6001;
      for (int step = 0; step < total; step++) {
        final double seconds = step * 0.1;
        if (world.threadsAt(seconds).any((ShowcaseThread thread) => thread.settled)) {
          settled++;
        }
      }
      // Require at least 95 % of frames to have a settled link.
      expect(settled / total, greaterThan(0.95),
          reason: 'only $settled/$total frames had a settled link');
    });

    test('only returns links that are actually visible', () {
      for (int step = 0; step <= 400; step++) {
        for (final ShowcaseThread thread in world.threadsAt(step * 0.37)) {
          expect(thread.opacity, greaterThan(0));
          expect(thread.opacity, lessThanOrEqualTo(1));
          expect(thread.progress, inInclusiveRange(0, 1));
          expect(thread.phase, inInclusiveRange(0, 1));
          if (thread.settled) expect(thread.progress, closeTo(1, 1e-9));
        }
      }
    });

    test('each link joins the person it belongs to with its hub', () {
      final List<MapPoint> hubs = world.hubs;
      final List<MapPoint> peers = world.peers;
      for (final ShowcaseThread thread in world.threadsAt(42.5)) {
        expect(thread.from.x, closeTo(peers[thread.peer].x, 1e-9));
        expect(thread.to.x, closeTo(hubs[thread.hub].x, 1e-9));
      }
    });

    test('is a pure function of time', () {
      final List<ShowcaseThread> first = world.threadsAt(31.25);
      final List<ShowcaseThread> second = world.threadsAt(31.25);
      expect(first.length, second.length);
      for (int i = 0; i < first.length; i++) {
        expect(first[i].peer, second[i].peer);
        expect(first[i].hub, second[i].hub);
        expect(first[i].progress, closeTo(second[i].progress, 1e-12));
        expect(first[i].opacity, closeTo(second[i].opacity, 1e-12));
      }
    });

    test('links fade and rebuild instead of blinking', () {
      // Opacity of one peer's link, sampled finely across its own cycle: no
      // step may jump by more than a small amount, or the eye reads it as a
      // flash rather than a connection coming up.
      double? previous;
      for (int step = 0; step <= 2600; step++) {
        final double seconds = step * 0.01;
        final ShowcaseThread? thread = world
            .threadsAt(seconds)
            .where((ShowcaseThread candidate) => candidate.peer == 0)
            .cast<ShowcaseThread?>()
            .firstWhere((ShowcaseThread? candidate) => candidate != null,
                orElse: () => null);
        final double opacity = thread?.opacity ?? 0;
        if (previous != null) {
          expect((opacity - previous).abs(), lessThan(0.2),
              reason: 'opacity jumped at ${seconds}s');
        }
        previous = opacity;
      }
    });
  });
}
