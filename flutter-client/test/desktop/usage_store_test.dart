// Requirement 18: session, daily and monthly traffic, kept locally so history
// survives "Remove device".
//
// These tests never touch the filesystem: AppPaths is pointed at a throwaway
// directory and only the in-memory accounting is exercised.

import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/desktop/services/app_paths.dart';
import 'package:glukvpn/desktop/state/usage_store.dart';

UsageStore newStore() => UsageStore(
      paths: AppPaths(
        appDataOverride: r'C:\GlukVpnTestData\AppData',
        programDataOverride: r'C:\GlukVpnTestData\ProgramData',
      ),
    );

void main() {
  group('bucket keys', () {
    test('day keys are sortable ISO dates', () {
      expect(UsageStore.dayKey(DateTime(2026, 8, 31)), '2026-08-31');
      expect(UsageStore.dayKey(DateTime(2026, 1, 5)), '2026-01-05');
    });

    test('month keys are zero padded', () {
      expect(UsageStore.monthKey(DateTime(2026, 8, 31)), '2026-08');
      expect(UsageStore.monthKey(DateTime(2026, 1, 5)), '2026-01');
    });

    test('lexical sort equals chronological sort', () {
      final keys = <String>[
        UsageStore.dayKey(DateTime(2026, 12, 1)),
        UsageStore.dayKey(DateTime(2026, 2, 9)),
        UsageStore.dayKey(DateTime(2025, 11, 30)),
      ]..sort();

      expect(keys, <String>['2025-11-30', '2026-02-09', '2026-12-01']);
    });
  });

  group('accounting', () {
    test('a fresh store reports nothing', () {
      final snapshot = newStore().snapshot(now: DateTime(2026, 8, 31));

      expect(snapshot.isEmpty, isTrue);
      expect(snapshot.today.totalBytes, 0);
      expect(snapshot.allTime.totalBytes, 0);
    });

    test('traffic lands in the day, month and all-time buckets at once', () {
      final store = newStore();
      final now = DateTime(2026, 8, 31, 14, 0);

      store.addForTesting(now, 1000, 400, 60);

      final snapshot = store.snapshot(now: now);
      expect(snapshot.today.rxBytes, 1000);
      expect(snapshot.today.txBytes, 400);
      expect(snapshot.today.seconds, 60);
      expect(snapshot.today.totalBytes, 1400);

      expect(snapshot.thisMonth.totalBytes, 1400);
      expect(snapshot.allTime.totalBytes, 1400);
      expect(snapshot.isEmpty, isFalse);
    });

    test('several sessions on one day accumulate', () {
      final store = newStore();
      final morning = DateTime(2026, 8, 31, 9);
      final evening = DateTime(2026, 8, 31, 21);

      store.addForTesting(morning, 500, 100, 30);
      store.addForTesting(evening, 250, 50, 15);

      final snapshot = store.snapshot(now: evening);
      expect(snapshot.today.rxBytes, 750);
      expect(snapshot.today.txBytes, 150);
      expect(snapshot.today.seconds, 45);
      expect(snapshot.today.duration, const Duration(seconds: 45));
    });

    test('yesterday does not count towards today, but does towards the month',
        () {
      final store = newStore();
      final yesterday = DateTime(2026, 8, 30, 12);
      final today = DateTime(2026, 8, 31, 12);

      store.addForTesting(yesterday, 900, 100, 60);
      store.addForTesting(today, 100, 0, 10);

      final snapshot = store.snapshot(now: today);
      expect(snapshot.today.totalBytes, 100);
      expect(snapshot.thisMonth.totalBytes, 1100);
      expect(snapshot.allTime.totalBytes, 1100);
    });

    test('last month is excluded from the month bucket but not from all time',
        () {
      final store = newStore();
      final lastMonth = DateTime(2026, 7, 20, 12);
      final today = DateTime(2026, 8, 31, 12);

      store.addForTesting(lastMonth, 5000, 1000, 300);
      store.addForTesting(today, 100, 0, 10);

      final snapshot = store.snapshot(now: today);
      expect(snapshot.thisMonth.totalBytes, 100);
      expect(snapshot.allTime.totalBytes, 6100);
    });
  });

  group('recent days', () {
    test('are limited and ordered newest last', () {
      final store = newStore();
      final today = DateTime(2026, 8, 31, 12);

      for (var i = 0; i < 20; i++) {
        store.addForTesting(today.subtract(Duration(days: i)), 100 * (i + 1),
            0, 60);
      }

      final snapshot = store.snapshot(now: today, recentDayCount: 7);
      expect(snapshot.recentDays.length, 7);

      final keys = snapshot.recentDays.map((b) => b.key).toList();
      final sorted = List<String>.from(keys)..sort();
      expect(keys, sorted, reason: 'chart bars must run oldest to newest');
      expect(keys.last, '2026-08-31');
    });
  });

  group('cumulative sampling', () {
    test('turns adapter counters into deltas', () {
      final store = newStore();
      final start = DateTime(2026, 8, 31, 12, 0, 0);

      store.beginSession(now: start);
      store.sample(
        cumulativeRx: 1000,
        cumulativeTx: 500,
        now: start.add(const Duration(seconds: 10)),
      );
      store.sample(
        cumulativeRx: 2500,
        cumulativeTx: 900,
        now: start.add(const Duration(seconds: 20)),
      );

      final snapshot = store.snapshot(now: start);
      expect(snapshot.today.rxBytes, 2500);
      expect(snapshot.today.txBytes, 900);
      expect(snapshot.today.seconds, greaterThanOrEqualTo(19));
    });

    test('a counter reset never produces negative traffic', () {
      // Reconnecting creates a brand new adapter whose counters start at zero.
      final store = newStore();
      final start = DateTime(2026, 8, 31, 12, 0, 0);

      store.beginSession(now: start);
      store.sample(
        cumulativeRx: 1000,
        cumulativeTx: 1000,
        now: start.add(const Duration(seconds: 10)),
      );
      store.sample(
        cumulativeRx: 200,
        cumulativeTx: 200,
        now: start.add(const Duration(seconds: 20)),
      );

      final snapshot = store.snapshot(now: start);
      expect(snapshot.today.rxBytes, greaterThanOrEqualTo(1000));
      expect(snapshot.today.rxBytes, lessThanOrEqualTo(1200));
      expect(snapshot.today.txBytes, greaterThanOrEqualTo(1000));
    });

    test('idle time after endSession is not counted as VPN time', () {
      final store = newStore();
      final start = DateTime(2026, 8, 31, 12, 0, 0);

      store.beginSession(now: start);
      store.sample(
        cumulativeRx: 100,
        cumulativeTx: 100,
        now: start.add(const Duration(seconds: 10)),
      );
      final connected = store.snapshot(now: start).today.seconds;

      store.endSession();
      store.sample(
        cumulativeRx: 200,
        cumulativeTx: 200,
        now: start.add(const Duration(hours: 3)),
      );

      final after = store.snapshot(now: start).today.seconds;
      expect(
        after - connected,
        lessThan(3600),
        reason: 'three idle hours must not become VPN time',
      );
    });
  });

  group('retention', () {
    test('is roughly thirteen months', () {
      expect(UsageStore.retentionDays, 400);
    });

    test('pruning keeps recent days', () {
      final store = newStore();
      final today = DateTime(2026, 8, 31, 12);

      store.addForTesting(today, 100, 0, 10);
      store.addForTesting(today.subtract(const Duration(days: 1)), 100, 0, 10);
      store.addForTesting(today.subtract(const Duration(days: 30)), 100, 0, 10);

      store.pruneForTesting(today);

      final snapshot = store.snapshot(now: today, recentDayCount: 60);
      expect(snapshot.recentDays.length, 3);
      expect(snapshot.allTime.totalBytes, 300);
    });
  });

  group('serialisation', () {
    test('produces a JSON-shaped map', () {
      final store = newStore();
      store.addForTesting(DateTime(2026, 8, 31, 12), 100, 50, 10);

      expect(store.toJson(), isA<Map<String, dynamic>>());
    });
  });
}
