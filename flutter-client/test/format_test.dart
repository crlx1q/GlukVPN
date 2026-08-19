import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/utils/format.dart';

void main() {
  group('countryFlag', () {
    test('derives the flag from the reported country code', () {
      expect(countryFlag('DE'), '\u{1F1E9}\u{1F1EA}');
      expect(countryFlag('US'), '\u{1F1FA}\u{1F1F8}');
    });

    test('is case and whitespace insensitive', () {
      expect(countryFlag('de'), countryFlag('DE'));
      expect(countryFlag(' de '), countryFlag('DE'));
    });

    test('falls back to a neutral flag for invalid codes', () {
      const String fallback = '\u{1F3F4}';
      expect(countryFlag(''), fallback);
      expect(countryFlag('D1'), fallback);
      expect(countryFlag('GERMANY'), fallback);
    });
  });

  group('formatDuration', () {
    test('uses MM:SS below an hour', () {
      expect(formatDuration(Duration.zero), '00:00');
      expect(formatDuration(const Duration(seconds: 65)), '01:05');
      expect(formatDuration(const Duration(minutes: 59, seconds: 59)), '59:59');
    });

    test('switches to HH:MM:SS past an hour', () {
      expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '01:02:03');
      expect(formatDuration(const Duration(hours: 25)), '25:00:00');
    });

    test('clamps negative durations', () {
      expect(formatDuration(const Duration(seconds: -30)), '00:00');
    });

    test('formatSeconds handles a missing value', () {
      expect(formatSeconds(null), '--:--');
      expect(formatSeconds(0), '00:00');
      expect(formatSeconds(3661), '01:01:01');
    });
  });

  group('formatBytes', () {
    test('scales WireGuard byte counters', () {
      expect(formatBytes(null), '0 B');
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(150 * 1024 * 1024), '150 MB');
      expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('treats negative counters as zero', () {
      expect(formatBytes(-5), '0 B');
    });
  });

  group('formatPing / formatPercent', () {
    test('shows placeholders when there is no sample', () {
      expect(formatPing(null), '--');
      expect(formatPercent(null), '--');
    });

    test('formats live values', () {
      expect(formatPing(42), '42 ms');
      expect(formatPercent(12.4), '12%');
      expect(formatPercent(99.6), '100%');
    });

    test('clamps percentages into range', () {
      expect(formatPercent(-4), '0%');
      expect(formatPercent(180), '100%');
    });
  });

  group('formatDateTime / formatRelative', () {
    test('formats a local timestamp', () {
      expect(formatDateTime(DateTime(2026, 8, 19, 16, 45)), '2026-08-19 16:45');
      expect(formatDateTime(DateTime(2026, 1, 2, 3, 4)), '2026-01-02 03:04');
      expect(formatDateTime(null), '--');
    });

    test('describes heartbeat age', () {
      expect(formatRelative(null), 'never');
      expect(formatRelative(DateTime.now().add(const Duration(minutes: 1))), 'just now');
      expect(formatRelative(DateTime.now().subtract(const Duration(seconds: 5))), endsWith('s ago'));
      expect(formatRelative(DateTime.now().subtract(const Duration(minutes: 7))), '7m ago');
      expect(formatRelative(DateTime.now().subtract(const Duration(hours: 3))), '3h ago');
      expect(formatRelative(DateTime.now().subtract(const Duration(days: 2))), '2d ago');
    });
  });

  group('formatUptime', () {
    test('collapses node uptime into a readable label', () {
      expect(formatUptime(null), '--');
      expect(formatUptime(90), '1m');
      expect(formatUptime(3700), '1h 1m');
      expect(formatUptime(90000), '1d 1h');
    });
  });
}
