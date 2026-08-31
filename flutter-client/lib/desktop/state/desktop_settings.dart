import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../platform/tunnel_backend.dart';
import '../services/app_paths.dart';

/// Persisted desktop preferences (%APPDATA%\GlukVPN\settings.json).
///
/// Deliberately a plain value object with explicit JSON mapping rather than
/// code generation, so it stays readable and forward-compatible: unknown keys
/// are ignored and missing keys fall back to defaults.
@immutable
class DesktopSettings {
  const DesktopSettings({
    this.startWithWindows = false,
    this.startMinimized = false,
    this.language = 'system',
    this.animationsEnabled = true,
    this.reduceMotion = false,
    this.pauseAnimationsOnBattery = true,
    this.autoConnect = false,
    this.killSwitch = false,
    this.dns = const <String>[],
    this.mtu,
    this.bypassRoutes = const <String>[],
    this.splitMode = SplitMode.allApps,
    this.splitApps = const <String>[],
    this.keepTunnelWithoutUi = true,
    this.disconnectOnExit = true,
    this.windowWidth,
    this.windowHeight,
    this.windowX,
    this.windowY,
    this.lastNodeId,
    this.autoNodeSelection = true,
  });

  /// Schema version of the stored file.
  ///
  /// 1 -> 2 drops the remembered window geometry once, because the window was
  /// reshaped (much closer to square) and an old 1165x739 rectangle would
  /// otherwise keep the new layout cramped for ever.
  static const int schemaVersion = 2;

  // --- General ---
  final bool startWithWindows;
  final bool startMinimized;

  /// 'system', 'ru', 'en'.
  final String language;

  /// The one and only animation switch the user sees.
  final bool animationsEnabled;

  /// Legacy "reduce motion" flag.
  ///
  /// It used to be a second, near-identical toggle next to Animations, which
  /// was confusing for no benefit. The UI no longer shows it; it is still read
  /// and written so an existing settings.json keeps working, and it still
  /// forces motion off when it was left on.
  final bool reduceMotion;

  /// Cut animations automatically on battery / in Windows battery saver.
  final bool pauseAnimationsOnBattery;

  // --- VPN ---
  final bool autoConnect;
  final bool killSwitch;
  final List<String> dns;

  /// Null means "use whatever the server hands us" (currently 1420).
  final int? mtu;

  /// Hosts, IPs and CIDRs that must always go straight out, never through the
  /// tunnel. Mirrors "Always direct" in the browser extension.
  final List<String> bypassRoutes;

  // --- Split tunnelling ---
  final SplitMode splitMode;
  final List<String> splitApps;

  // --- Lifecycle ---
  /// Requirement 11: closing the window must not drop the tunnel.
  final bool keepTunnelWithoutUi;

  /// Requirement 11: Exit from tray disconnects before quitting.
  final bool disconnectOnExit;

  // --- Window geometry ---
  final double? windowWidth;
  final double? windowHeight;
  final double? windowX;
  final double? windowY;

  // --- Server memory ---
  final String? lastNodeId;
  final bool autoNodeSelection;

  static const DesktopSettings defaults = DesktopSettings();

  /// True when the UI should hold still, whatever the reason.
  ///
  /// [onBattery] comes from [PowerMonitor]. Requirement 15: this only ever
  /// affects motion, never the tunnel.
  bool motionDisabled({bool onBattery = false}) {
    if (!animationsEnabled) return true;
    if (reduceMotion) return true;
    if (pauseAnimationsOnBattery && onBattery) return true;
    return false;
  }

  /// WireGuard tolerates 1280..1500; anything else breaks path MTU.
  static int? clampMtu(int? value) {
    if (value == null) return null;
    if (value < 1280) return 1280;
    if (value > 1500) return 1500;
    return value;
  }

  DesktopSettings copyWith({
    bool? startWithWindows,
    bool? startMinimized,
    String? language,
    bool? animationsEnabled,
    bool? reduceMotion,
    bool? pauseAnimationsOnBattery,
    bool? autoConnect,
    bool? killSwitch,
    List<String>? dns,
    int? mtu,
    bool clearMtu = false,
    List<String>? bypassRoutes,
    SplitMode? splitMode,
    List<String>? splitApps,
    bool? keepTunnelWithoutUi,
    bool? disconnectOnExit,
    double? windowWidth,
    double? windowHeight,
    double? windowX,
    double? windowY,
    String? lastNodeId,
    bool clearLastNodeId = false,
    bool? autoNodeSelection,
  }) {
    return DesktopSettings(
      startWithWindows: startWithWindows ?? this.startWithWindows,
      startMinimized: startMinimized ?? this.startMinimized,
      language: language ?? this.language,
      animationsEnabled: animationsEnabled ?? this.animationsEnabled,
      reduceMotion: reduceMotion ?? this.reduceMotion,
      pauseAnimationsOnBattery:
          pauseAnimationsOnBattery ?? this.pauseAnimationsOnBattery,
      autoConnect: autoConnect ?? this.autoConnect,
      killSwitch: killSwitch ?? this.killSwitch,
      dns: dns ?? this.dns,
      mtu: clearMtu ? null : clampMtu(mtu ?? this.mtu),
      bypassRoutes: bypassRoutes ?? this.bypassRoutes,
      splitMode: splitMode ?? this.splitMode,
      splitApps: splitApps ?? this.splitApps,
      keepTunnelWithoutUi: keepTunnelWithoutUi ?? this.keepTunnelWithoutUi,
      disconnectOnExit: disconnectOnExit ?? this.disconnectOnExit,
      windowWidth: windowWidth ?? this.windowWidth,
      windowHeight: windowHeight ?? this.windowHeight,
      windowX: windowX ?? this.windowX,
      windowY: windowY ?? this.windowY,
      lastNodeId: clearLastNodeId ? null : (lastNodeId ?? this.lastNodeId),
      autoNodeSelection: autoNodeSelection ?? this.autoNodeSelection,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': schemaVersion,
        'startWithWindows': startWithWindows,
        'startMinimized': startMinimized,
        'language': language,
        'animationsEnabled': animationsEnabled,
        'reduceMotion': reduceMotion,
        'pauseAnimationsOnBattery': pauseAnimationsOnBattery,
        'autoConnect': autoConnect,
        'killSwitch': killSwitch,
        'dns': dns,
        'mtu': mtu,
        'bypassRoutes': bypassRoutes,
        'splitMode': splitModeWire(splitMode),
        'splitApps': splitApps,
        'keepTunnelWithoutUi': keepTunnelWithoutUi,
        'disconnectOnExit': disconnectOnExit,
        'windowWidth': windowWidth,
        'windowHeight': windowHeight,
        'windowX': windowX,
        'windowY': windowY,
        'lastNodeId': lastNodeId,
        'autoNodeSelection': autoNodeSelection,
      };

  factory DesktopSettings.fromJson(Map<String, dynamic> json) {
    List<String> strings(Object? value) {
      if (value is List) {
        return value
            .whereType<Object>()
            .map((Object e) => e.toString())
            .where((String e) => e.isNotEmpty)
            .toList(growable: false);
      }
      return const <String>[];
    }

    bool flag(String key, bool fallback) {
      final value = json[key];
      return value is bool ? value : fallback;
    }

    double? real(String key) {
      final value = json[key];
      if (value is num) return value.toDouble();
      return null;
    }

    int? whole(String key) {
      final value = json[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      return null;
    }

    // Migration: a file written before the window was reshaped keeps its old
    // rectangle. Forgetting it once lets the new default apply, and the very
    // next move or resize stores the user's own choice again.
    final int version = whole('version') ?? 1;
    final bool keepGeometry = version >= 2;

    return DesktopSettings(
      startWithWindows: flag('startWithWindows', false),
      startMinimized: flag('startMinimized', false),
      language: (json['language'] as String?) ?? 'system',
      animationsEnabled: flag('animationsEnabled', true),
      reduceMotion: flag('reduceMotion', false),
      pauseAnimationsOnBattery: flag('pauseAnimationsOnBattery', true),
      autoConnect: flag('autoConnect', false),
      killSwitch: flag('killSwitch', false),
      dns: strings(json['dns']),
      mtu: clampMtu(whole('mtu')),
      bypassRoutes: strings(json['bypassRoutes']),
      splitMode: splitModeFromWire(json['splitMode'] as String?),
      splitApps: strings(json['splitApps']),
      keepTunnelWithoutUi: flag('keepTunnelWithoutUi', true),
      disconnectOnExit: flag('disconnectOnExit', true),
      windowWidth: keepGeometry ? real('windowWidth') : null,
      windowHeight: keepGeometry ? real('windowHeight') : null,
      windowX: keepGeometry ? real('windowX') : null,
      windowY: keepGeometry ? real('windowY') : null,
      lastNodeId: json['lastNodeId'] as String?,
      autoNodeSelection: flag('autoNodeSelection', true),
    );
  }
}

/// Loads and saves [DesktopSettings], and notifies listeners on change.
///
/// Writes are atomic (temp file + rename) so a crash mid-save can never leave
/// a truncated settings.json behind.
class SettingsStore extends ChangeNotifier {
  SettingsStore({AppPaths? paths}) : _paths = paths ?? AppPaths();

  final AppPaths _paths;

  DesktopSettings _value = DesktopSettings.defaults;
  bool _loaded = false;

  DesktopSettings get value => _value;
  bool get loaded => _loaded;

  Future<DesktopSettings> load() async {
    try {
      final file = File(_paths.settingsFilePath);
      if (await file.exists()) {
        final text = await file.readAsString();
        if (text.trim().isNotEmpty) {
          final decoded = jsonDecode(text);
          if (decoded is Map<String, dynamic>) {
            _value = DesktopSettings.fromJson(decoded);
          }
        }
      }
    } catch (_) {
      // Corrupt file: fall back to defaults rather than blocking startup.
      _value = DesktopSettings.defaults;
    }
    _loaded = true;
    notifyListeners();
    return _value;
  }

  Future<void> save(DesktopSettings next) async {
    _value = next;
    notifyListeners();
    await _persist();
  }

  Future<void> update(
    DesktopSettings Function(DesktopSettings current) mutate,
  ) async {
    await save(mutate(_value));
  }

  Future<void> _persist() async {
    try {
      await _paths.ensureCreated();
      final target = File(_paths.settingsFilePath);
      final temp = File('${_paths.settingsFilePath}.tmp');
      const encoder = JsonEncoder.withIndent('  ');
      await temp.writeAsString(encoder.convert(_value.toJson()), flush: true);
      if (await target.exists()) {
        await target.delete();
      }
      await temp.rename(target.path);
    } catch (_) {
      // Never let a settings write failure take down the app.
    }
  }
}
