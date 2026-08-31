import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

import 'desktop_log.dart';

/// Watches the power source so animations can stand down on battery.
///
/// Requirement 15, restated by the user: there should be exactly one animation
/// switch, and the app should turn animations off by itself when the laptop is
/// unplugged or in Windows battery-saver mode. The VPN lifecycle is never
/// affected - only motion.
///
/// battery_plus is already a dependency of the mobile app, so nothing new is
/// pulled in. Desktops without a battery simply report `discharging == false`,
/// and every call is defensive: a plugin failure means "assume mains power"
/// rather than silently freezing the UI.
class PowerMonitor extends ChangeNotifier {
  PowerMonitor({Battery? battery}) : _battery = battery ?? Battery();

  final Battery _battery;

  StreamSubscription<BatteryState>? _sub;
  Timer? _saverPoll;
  bool _disposed = false;

  bool _onBattery = false;
  bool _saverMode = false;
  bool _available = true;

  /// True when the machine is running off its battery.
  bool get onBattery => _onBattery;

  /// True when Windows battery saver is on.
  bool get saverMode => _saverMode;

  /// True when the platform could be queried at all.
  bool get available => _available;

  /// What the UI asks: should motion be cut back right now?
  bool get shouldReduceMotion => _onBattery || _saverMode;

  Future<void> start() async {
    await _refresh();

    try {
      _sub = _battery.onBatteryStateChanged.listen(
        (BatteryState state) {
          final bool next = state == BatteryState.discharging;
          if (next == _onBattery) return;
          _onBattery = next;
          dlog.write('power', 'on battery -> $next');
          _notify();
        },
        onError: (Object error) {
          dlog.warn('power', 'battery stream error: $error');
        },
        cancelOnError: false,
      );
    } catch (e) {
      _available = false;
      dlog.warn('power', 'battery stream unavailable: $e');
    }

    // Battery saver has no event, so it is polled - cheaply, once a minute.
    _saverPoll?.cancel();
    _saverPoll = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_refreshSaver());
    });
  }

  Future<void> _refresh() async {
    try {
      final BatteryState state = await _battery.batteryState;
      _onBattery = state == BatteryState.discharging;
    } catch (e) {
      _available = false;
      _onBattery = false;
      dlog.warn('power', 'batteryState unavailable: $e');
    }
    await _refreshSaver();
    _notify();
  }

  Future<void> _refreshSaver() async {
    try {
      final bool saver = await _battery.isInBatterySaveMode;
      if (saver == _saverMode) return;
      _saverMode = saver;
      dlog.write('power', 'battery saver -> $saver');
      _notify();
    } catch (_) {
      // Not supported on every Windows build; not worth a log line a minute.
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _saverPoll?.cancel();
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
