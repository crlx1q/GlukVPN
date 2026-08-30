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
    this.autoConnect = false,
    this.killSwitch = false,
    this.dns = const <String>[],
    this.mtu,
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

  // --- General ---
  final bool startWithWindows;
  final bool startMinimized;

  /// 'system', 'ru', 'en'.
  final String language;
  final bool animationsEnabled;
  final bool reduceMotion;

  // --- VPN ---
  final bool autoConnect;
  final bool killSwitch;
  final List<String> dns;

  /// Null means "use whatever the server hands us" (currently 1420).
  final int? mtu;

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
    bool? autoConnect,
    bool? killSwitch,
    List<String>? dns,
    int? mtu,
    bool clearMtu = false,
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
      autoConnect: autoConnect ?? this.autoConnect,
      killSwitch: killSwitch ?? this.killSwitch,
      dns: dns ?? this.dns,
      mtu: clearMtu ? null : clampMtu(mtu ?? this.mtu),
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
        'version': 1,
        'startWithWindows': startWithWindows,
        'startMinimized': startMinimized,
        'language': language,
        'animationsEnabled': animationsEnabled,
        'reduceMotion': reduceMotion,
        'autoConnect': autoConnect,
        'killSwitch': killSwitch,
        'dns': dns,
        'mtu': mtu,
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

    return DesktopSettings(
      startWithWindows: flag('startWithWindows', false),
      startMinimized: flag('startMinimized', false),
      language: (json['language'] as String?) ?? 'system',
      animationsEnabled: flag('animationsEnabled', true),
      reduceMotion: flag('reduceMotion', false),
      autoConnect: flag('autoConnect', false),
      killSwitch: flag('killSwitch', false),
      dns: strings(json['dns']),
      mtu: clampMtu(whole('mtu')),
      splitMode: splitModeFromWire(json['splitMode'] as String?),
      splitApps: strings(json['splitApps']),
      keepTunnelWithoutUi: flag('keepTunnelWithoutUi', true),
      disconnectOnExit: flag('disconnectOnExit', true),
      windowWidth: real('windowWidth'),
      windowHeight: real('windowHeight'),
      windowX: real('windowX'),
      windowY: real('windowY'),
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
