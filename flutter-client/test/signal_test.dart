import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/utils/signal.dart';

/// The three-bar meter has to be arithmetic, not decoration: a node earns bars
/// from its own numbers. These tests pin the rules down.
void main() {
  group('bars and colours', () {
    test('each level lights the expected number of bars', () {
      expect(SignalStrength.strong.bars, 3);
      expect(SignalStrength.fair.bars, 2);
      expect(SignalStrength.weak.bars, 1);
      expect(SignalStrength.offline.bars, 0);
    });

    test('every level says something a screen reader can use', () {
      for (final SignalStrength level in SignalStrength.values) {
        expect(level.label, isNotEmpty);
      }
    });
  });

  group('signalStrengthFor', () {
    test('an offline or unavailable node has no bars at all', () {
      expect(
        signalStrengthFor(online: false, pingMs: 12, loadPercent: 1),
        SignalStrength.offline,
      );
      expect(
        signalStrengthFor(online: true, available: false, pingMs: 12),
        SignalStrength.offline,
      );
    });

    test('low latency on a quiet node is three bars', () {
      expect(
        signalStrengthFor(online: true, pingMs: 25, loadPercent: 8),
        SignalStrength.strong,
      );
      expect(
        signalStrengthFor(online: true, pingMs: 60, loadPercent: 30),
        SignalStrength.strong,
      );
    });

    test('a middling round trip is two bars', () {
      expect(
        signalStrengthFor(online: true, pingMs: 140, loadPercent: 50),
        SignalStrength.fair,
      );
    });

    test('high latency is one bar however empty the node is', () {
      expect(
        signalStrengthFor(online: true, pingMs: 210, loadPercent: 2),
        SignalStrength.weak,
      );
    });

    test('a nearly full node is one bar however fast it answers', () {
      expect(
        signalStrengthFor(online: true, pingMs: 20, loadPercent: 93),
        SignalStrength.weak,
      );
    });

    test('a busy but not full node loses one bar, not two', () {
      expect(
        signalStrengthFor(online: true, pingMs: 30, loadPercent: 75),
        SignalStrength.fair,
      );
    });

    test('without a ping sample it never claims three bars', () {
      expect(
        signalStrengthFor(online: true, loadPercent: 5),
        SignalStrength.fair,
      );
    });

    test('the score is monotonic in both inputs', () {
      expect(
        signalScore(pingMs: 20, loadPercent: 10),
        greaterThan(signalScore(pingMs: 90, loadPercent: 10)),
      );
      expect(
        signalScore(pingMs: 20, loadPercent: 10),
        greaterThan(signalScore(pingMs: 20, loadPercent: 80)),
      );
      expect(signalScore(pingMs: 5, loadPercent: 0), closeTo(1, 1e-9));
      expect(signalScore(pingMs: 900, loadPercent: 100), closeTo(0, 1e-9));
    });

    test('country plays no part in it', () {
      // Same country, same node, different measurements: different bars.
      final SignalStrength good =
          signalStrengthFor(online: true, pingMs: 28, loadPercent: 12);
      final SignalStrength bad =
          signalStrengthFor(online: true, pingMs: 240, loadPercent: 12);
      expect(good, isNot(bad));
    });
  });
}
