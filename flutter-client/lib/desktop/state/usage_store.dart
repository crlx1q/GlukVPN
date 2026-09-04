import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/app_paths.dart';

/// One aggregated traffic bucket (a day, a month, or all time).
@immutable
class UsageBucket {
  const UsageBucket({
    required this.key,
    this.rxBytes = 0,
    this.txBytes = 0,
    this.seconds = 0,
  });

  /// 'YYYY-MM-DD', 'YYYY-MM' or 'all'.
  final String key;
  final int rxBytes;
  final int txBytes;
  final int seconds;

  int get totalBytes => rxBytes + txBytes;

  Duration get duration => Duration(seconds: seconds);

  UsageBucket plus({int rx = 0, int tx = 0, int secs = 0}) => UsageBucket(
        key: key,
        rxBytes: rxBytes + rx,
        txBytes: txBytes + tx,
        seconds: seconds + secs,
      );

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'rx': rxBytes, 'tx': txBytes, 's': seconds};

  factory UsageBucket.fromJson(String key, Map<String, dynamic> json) {
    int whole(String name) {
      final value = json[name];
      if (value is int) return value;
      if (value is num) return value.toInt();
      return 0;
    }

    return UsageBucket(
      key: key,
      rxBytes: whole('rx'),
      txBytes: whole('tx'),
      seconds: whole('s'),
    );
  }
}

/// Everything the statistics screen renders.
@immutable
class UsageSnapshot {
  const UsageSnapshot({
    required this.today,
    required this.thisMonth,
    required this.allTime,
    required this.recentDays,
  });

  final UsageBucket today;
  final UsageBucket thisMonth;
  final UsageBucket allTime;

  /// Most recent first, capped by the caller.
  final List<UsageBucket> recentDays;

  bool get isEmpty => allTime.totalBytes == 0 && allTime.seconds == 0;

  static UsageSnapshot empty(DateTime now) => UsageSnapshot(
        today: UsageBucket(key: UsageStore.dayKey(now)),
        thisMonth: UsageBucket(key: UsageStore.monthKey(now)),
        allTime: const UsageBucket(key: 'all'),
        recentDays: const <UsageBucket>[],
      );
}

/// Local traffic history (%APPDATA%\GlukVPN\usage.json).
///
/// Requirement 18: history must survive "Remove device", so it is stored
/// locally and keyed by the account's public id rather than the device id.
/// If a different account signs in on this machine the buckets reset, which
/// keeps one user's traffic from leaking into another's statistics.
class UsageStore extends ChangeNotifier {
  UsageStore({AppPaths? paths}) : _paths = paths ?? AppPaths();

  final AppPaths _paths;

  /// Roughly 13 months; enough for a year-over-year view without unbounded
  /// growth.
  static const int retentionDays = 400;

  String? _owner;
  final Map<String, UsageBucket> _days = <String, UsageBucket>{};
  final Map<String, UsageBucket> _months = <String, UsageBucket>{};
  UsageBucket _allTime = const UsageBucket(key: 'all');

  // Last observed cumulative counters, used to derive deltas.
  int _lastRx = 0;
  int _lastTx = 0;
  DateTime? _lastSampleAt;

  bool _dirty = false;
  bool _loaded = false;

  /// True once [load] has run, whatever it found. Until then the statistics
  /// screen shows skeletons rather than zeros that are about to change.
  bool get loaded => _loaded;

  static String dayKey(DateTime at) {
    final local = at.toLocal();
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '${local.year}-$m-$d';
  }

  static String monthKey(DateTime at) {
    final local = at.toLocal();
    final m = local.month.toString().padLeft(2, '0');
    return '${local.year}-$m';
  }

  Future<void> load({String? owner}) async {
    try {
      final file = File(_paths.usageFilePath);
      if (await file.exists()) {
        final text = await file.readAsString();
        if (text.trim().isNotEmpty) {
          final decoded = jsonDecode(text);
          if (decoded is Map<String, dynamic>) {
            _hydrate(decoded);
          }
        }
      }
    } catch (_) {
      _reset();
    }

    if (owner != null && _owner != null && _owner != owner) {
      // Different account on the same machine: start clean.
      _reset();
    }
    if (owner != null) _owner = owner;

    _prune(DateTime.now());
    _loaded = true;
    notifyListeners();
  }

  void _hydrate(Map<String, dynamic> json) {
    _reset();
    _owner = json['owner'] as String?;

    final days = json['days'];
    if (days is Map) {
      days.forEach((Object? k, Object? v) {
        if (k is String && v is Map<String, dynamic>) {
          _days[k] = UsageBucket.fromJson(k, v);
        }
      });
    }

    final months = json['months'];
    if (months is Map) {
      months.forEach((Object? k, Object? v) {
        if (k is String && v is Map<String, dynamic>) {
          _months[k] = UsageBucket.fromJson(k, v);
        }
      });
    }

    final all = json['allTime'];
    if (all is Map<String, dynamic>) {
      _allTime = UsageBucket.fromJson('all', all);
    }
  }

  void _reset() {
    _days.clear();
    _months.clear();
    _allTime = const UsageBucket(key: 'all');
    _owner = null;
  }

  /// Call when a new tunnel session starts, so the first delta is not the
  /// whole previous session's counters.
  void beginSession({DateTime? now}) {
    _lastRx = 0;
    _lastTx = 0;
    _lastSampleAt = now ?? DateTime.now();
  }

  /// Feed cumulative adapter counters. Handles counter resets (a new adapter
  /// starts at zero) by treating any decrease as a fresh baseline.
  void sample({
    required int cumulativeRx,
    required int cumulativeTx,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();

    var deltaRx = cumulativeRx - _lastRx;
    var deltaTx = cumulativeTx - _lastTx;
    if (deltaRx < 0) deltaRx = cumulativeRx;
    if (deltaTx < 0) deltaTx = cumulativeTx;

    final previous = _lastSampleAt;
    var deltaSeconds = 0;
    if (previous != null) {
      final gap = at.difference(previous).inSeconds;
      // Guard against sleep/hibernate producing an absurd jump.
      deltaSeconds = gap.clamp(0, 300);
    }

    _lastRx = cumulativeRx;
    _lastTx = cumulativeTx;
    _lastSampleAt = at;

    if (deltaRx == 0 && deltaTx == 0 && deltaSeconds == 0) return;

    _add(at, deltaRx, deltaTx, deltaSeconds);
  }

  void _add(DateTime at, int rx, int tx, int secs) {
    final dKey = dayKey(at);
    final mKey = monthKey(at);

    _days[dKey] =
        (_days[dKey] ?? UsageBucket(key: dKey)).plus(rx: rx, tx: tx, secs: secs);
    _months[mKey] = (_months[mKey] ?? UsageBucket(key: mKey))
        .plus(rx: rx, tx: tx, secs: secs);
    _allTime = _allTime.plus(rx: rx, tx: tx, secs: secs);

    _dirty = true;
    notifyListeners();
  }

  /// Ends the current session so idle time is not counted as VPN time.
  void endSession() {
    _lastSampleAt = null;
  }

  UsageSnapshot snapshot({DateTime? now, int recentDayCount = 14}) {
    final at = now ?? DateTime.now();
    final dKey = dayKey(at);
    final mKey = monthKey(at);

    final keys = _days.keys.toList()..sort();
    final start = keys.length > recentDayCount ? keys.length - recentDayCount : 0;
    final recent = keys
        .sublist(start)
        .map((String k) => _days[k]!)
        .toList(growable: false);

    return UsageSnapshot(
      today: _days[dKey] ?? UsageBucket(key: dKey),
      thisMonth: _months[mKey] ?? UsageBucket(key: mKey),
      allTime: _allTime,
      recentDays: recent,
    );
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(const Duration(days: retentionDays));
    final cutoffKey = dayKey(cutoff);
    final stale = _days.keys.where((String k) => k.compareTo(cutoffKey) < 0).toList();
    if (stale.isEmpty) return;
    for (final key in stale) {
      _days.remove(key);
    }
    _dirty = true;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'owner': _owner,
        'days': _days.map(
          (String k, UsageBucket v) => MapEntry<String, dynamic>(k, v.toJson()),
        ),
        'months': _months.map(
          (String k, UsageBucket v) => MapEntry<String, dynamic>(k, v.toJson()),
        ),
        'allTime': _allTime.toJson(),
      };

  /// Atomic save. Called periodically and on shutdown.
  Future<void> flush({bool force = false}) async {
    if (!_dirty && !force) return;
    try {
      await _paths.ensureCreated();
      final target = File(_paths.usageFilePath);
      final temp = File('${_paths.usageFilePath}.tmp');
      await temp.writeAsString(jsonEncode(toJson()), flush: true);
      if (await target.exists()) {
        await target.delete();
      }
      await temp.rename(target.path);
      _dirty = false;
    } catch (_) {
      // Statistics are not worth crashing over.
    }
  }

  /// Test hook.
  @visibleForTesting
  void addForTesting(DateTime at, int rx, int tx, int secs) =>
      _add(at, rx, tx, secs);

  @visibleForTesting
  void pruneForTesting(DateTime now) => _prune(now);

  @visibleForTesting
  String? get ownerForTesting => _owner;

  @visibleForTesting
  void hydrateForTesting(Map<String, dynamic> json) => _hydrate(json);
}
