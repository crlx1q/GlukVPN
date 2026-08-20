import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// Is our control plane reachable right now?
///
/// Deliberately not a connectivity plugin. "The phone has a Wi-Fi association"
/// is not the question that matters here - captive portals, dead hotel Wi-Fi
/// and a half-open tunnel all report a perfectly good network while nothing
/// actually answers. Asking `/api/health` gives a truthful answer, needs no
/// extra Android permission and no extra dependency.
///
/// The rule this service exists to enforce: losing the network is a *transient*
/// state. It shows an overlay, it never signs anybody out.
class ConnectivityService extends ChangeNotifier {
  ConnectivityService({
    required ApiClient api,
    Duration onlineInterval = const Duration(seconds: 25),
  })  : _api = api,
        _onlineInterval = onlineInterval;

  final ApiClient _api;
  final Duration _onlineInterval;

  /// Backoff while offline: quick first retries, then calm down. Retrying every
  /// second on a dead network only drains the battery.
  static const List<Duration> _offlineBackoff = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  bool _online = true;
  bool _checking = false;
  int _failures = 0;
  DateTime? _lastOnlineAt;
  Timer? _timer;
  bool _disposed = false;

  /// True until something proves otherwise, so a cold start does not flash an
  /// offline overlay before the first probe finishes.
  bool get online => _online;
  bool get checking => _checking;
  bool get offline => !_online;
  DateTime? get lastOnlineAt => _lastOnlineAt;

  /// Fired when connectivity returns, so the session can be resumed.
  VoidCallback? onBackOnline;

  Duration get _nextDelay {
    if (_online) return _onlineInterval;
    final int index = _failures - 1;
    if (index < 0) return _offlineBackoff.first;
    return index >= _offlineBackoff.length
        ? _offlineBackoff.last
        : _offlineBackoff[index];
  }

  void start() {
    if (_disposed) return;
    _schedule();
    // Fire once immediately: the very first frame should already know.
    check();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed) return;
    _timer = Timer(_nextDelay, () {
      check();
    });
  }

  /// One reachability probe. Never throws.
  Future<bool> check() async {
    if (_disposed || _checking) return _online;
    _checking = true;
    notifyListeners();
    bool ok;
    try {
      ok = await _api.health();
    } on ApiException {
      ok = false;
    } catch (_) {
      ok = false;
    }
    _checking = false;
    _apply(ok);
    _schedule();
    return ok;
  }

  /// Called by controllers that just saw a transport-level failure, so the
  /// overlay appears without waiting for the next scheduled probe.
  void reportNetworkFailure() {
    if (_disposed) return;
    if (_online) {
      _apply(false);
      _schedule();
    }
  }

  /// Called after any successful request: cheaper and faster than a probe.
  void reportSuccess() {
    if (_disposed) return;
    if (!_online) {
      _apply(true);
      _schedule();
    } else {
      _lastOnlineAt = DateTime.now();
    }
  }

  void _apply(bool ok) {
    final bool was = _online;
    _online = ok;
    if (ok) {
      _failures = 0;
      _lastOnlineAt = DateTime.now();
    } else {
      _failures += 1;
    }
    if (_disposed) return;
    notifyListeners();
    // Only on the transition, so a flapping network does not spam refreshes.
    if (!was && ok) onBackOnline?.call();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
