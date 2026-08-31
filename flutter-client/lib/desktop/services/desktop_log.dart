import 'dart:collection';
import 'dart:io';

import 'app_paths.dart';

/// Tiny append-only diagnostic log for the desktop client.
///
/// Why this exists: the first Windows build failed silently. The node list was
/// empty, the connect button did nothing, and there was no way to tell whether
/// the control API, the device registration or the tunnel service was at
/// fault. Every failure path now records a line here, the last 400 lines are
/// kept in memory for the in-app diagnostics panel, and the same lines land in
/// `%APPDATA%\GlukVPN\logs\ui.log`.
///
/// Secrets are scrubbed before writing: WireGuard keys and bearer tokens are
/// replaced with a placeholder, so the file can be pasted into a bug report
/// as-is.
class DesktopLog {
  DesktopLog._();

  static final DesktopLog instance = DesktopLog._();

  static const int _maxMemoryLines = 400;
  static const int _maxFileBytes = 512 * 1024;

  final Queue<String> _ring = Queue<String>();
  AppPaths? _paths;
  bool _fileBroken = false;

  /// Base64-ish blobs of 32+ chars: WireGuard keys, JWTs, refresh tokens.
  static final RegExp _secretPattern =
      RegExp(r'[A-Za-z0-9+/_-]{32,}={0,2}');

  /// Called once from the Windows entry point.
  void attach(AppPaths paths) {
    _paths = paths;
    _rotateIfNeeded();
    write('boot', 'log attached: ${paths.uiLogPath}');
  }

  /// Most recent lines, oldest first.
  List<String> get lines => List<String>.unmodifiable(_ring);

  /// Whole buffer as one clipboard-ready string.
  String dump() => _ring.join('\n');

  void write(String tag, String message) => _emit('INFO', tag, message);

  void warn(String tag, String message) => _emit('WARN', tag, message);

  void error(String tag, String message, [Object? cause]) {
    _emit('FAIL', tag, cause == null ? message : '$message :: $cause');
  }

  void _emit(String level, String tag, String message) {
    final String stamp = DateTime.now().toIso8601String();
    final String line = '$stamp $level [$tag] ${scrub(message)}';

    _ring.addLast(line);
    while (_ring.length > _maxMemoryLines) {
      _ring.removeFirst();
    }

    _appendToFile(line);
  }

  void _appendToFile(String line) {
    if (_fileBroken) return;
    final AppPaths? paths = _paths;
    if (paths == null) return;

    try {
      File(paths.uiLogPath).writeAsStringSync(
        '$line\r\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {
      // A read-only or missing profile directory must never crash the client;
      // the in-memory ring still backs the diagnostics panel.
      _fileBroken = true;
    }
  }

  /// Keeps ui.log bounded. Called once at startup, which is often enough for a
  /// log that only records state transitions.
  void _rotateIfNeeded() {
    final AppPaths? paths = _paths;
    if (paths == null) return;
    try {
      final File file = File(paths.uiLogPath);
      if (!file.existsSync()) return;
      if (file.lengthSync() <= _maxFileBytes) return;

      // Keep the tail: the interesting part of a log is always the end.
      final List<String> kept = file.readAsLinesSync();
      final int from =
          kept.length > _maxMemoryLines ? kept.length - _maxMemoryLines : 0;
      file.writeAsStringSync('${kept.sublist(from).join('\r\n')}\r\n');
    } catch (_) {
      _fileBroken = true;
    }
  }

  /// Replaces anything that looks like a key or token.
  static String scrub(String input) {
    if (input.isEmpty) return input;
    return input.replaceAllMapped(_secretPattern, (Match m) {
      final String hit = m.group(0)!;
      // Leave ordinary long words alone: real secrets mix cases and digits.
      final bool looksRandom = RegExp(r'[0-9]').hasMatch(hit) &&
          RegExp(r'[A-Z]').hasMatch(hit) &&
          RegExp(r'[a-z]').hasMatch(hit);
      if (!looksRandom) return hit;
      return '<redacted:${hit.length}>';
    });
  }
}

/// Shorthand used across the desktop layer.
DesktopLog get dlog => DesktopLog.instance;
