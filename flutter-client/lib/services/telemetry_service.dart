import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

import '../config.dart';

/// Ships uncaught client errors to the control server's bug log.
///
/// Installed in `lib/main.dart` (Android) and `lib/main_windows.dart` (Windows)
/// through `FlutterError.onError` and `PlatformDispatcher.instance.onError`, so
/// a crash on somebody else's machine is still debuggable:
///
///   POST {base}/api/telemetry/error
///
/// Deliberate constraints, because a crash reporter that makes the crash worse
/// is not worth shipping:
///  * [report] never throws and never blocks a frame - every failure path is
///    swallowed, including `MissingPluginException` under a headless test
///    runner;
///  * the same error is reported at most once a minute (a failing poll throws
///    again on every tick) and one run is capped at [maxPerSession] reports;
///  * only the error travels: no request bodies, no tokens, no passwords. Any
///    that slip into a message are redacted here, and the server scrubs again
///    on arrival.
class TelemetryService {
  TelemetryService({
    http.Client? client,
    String? baseUrl,
    String? platform,
    String? appVersion,
    this.dedupeWindow = const Duration(minutes: 1),
    this.maxPerSession = 20,
    this.timeout = const Duration(seconds: 6),
  })  : _client = client,
        _baseUrl = baseUrl,
        _platform = platform,
        _appVersion = appVersion;

  final http.Client? _client;
  final String? _baseUrl;
  final String? _platform;
  final String? _appVersion;

  /// How long the same error stays muted after it was reported once.
  final Duration dedupeWindow;

  /// Upper bound for one app run, so a tight loop cannot flood the table.
  final int maxPerSession;

  /// A report is never worth waiting on: the request is cut short instead.
  final Duration timeout;

  final Map<String, DateTime> _recent = <String, DateTime>{};
  int _sent = 0;
  bool _enabled = true;
  String? _deviceId;

  static TelemetryService? _shared;

  /// The instance the global error hooks report through.
  static TelemetryService get instance => _shared ??= TelemetryService();

  static set instance(TelemetryService service) => _shared = service;

  /// "windows" or "android" - the same values the control server validates.
  String get platform =>
      _platform ?? (Platform.isAndroid ? 'android' : 'windows');

  String get appVersion => _appVersion ?? AppConfig.appVersion;

  /// Read late on purpose: switching channel moves the bug log with it.
  String get baseUrl => _trimSlashes(_baseUrl ?? AppConfig.activeBaseUrl);

  /// How many reports actually left this device during the current run.
  int get sentCount => _sent;

  /// Tie later reports to a device row in the admin panel.
  void attachDevice(String? deviceId) {
    _deviceId = (deviceId == null || deviceId.isEmpty) ? null : deviceId;
  }

  /// Kill switch for the whole reporter.
  void setEnabled(bool value) {
    _enabled = value;
  }

  /// Fire and forget. Safe to call from inside an error handler.
  void report(Object? error, StackTrace? stack, {String? context}) {
    unawaited(send(error, stack, context: context));
  }

  /// Awaitable variant of [report]. True when a report was actually sent.
  Future<bool> send(
    Object? error,
    StackTrace? stack, {
    String? context,
  }) async {
    try {
      if (!_enabled) return false;

      final _Described described = _describe(error);
      final String? where =
          context == null ? null : _clip(context, _contextLimit);
      final String key =
          '${described.name}|${described.message}|${where ?? ''}';

      final DateTime now = DateTime.now();
      final DateTime? last = _recent[key];
      if (last != null && now.difference(last) < dedupeWindow) return false;
      if (_sent >= maxPerSession) return false;

      final String base = baseUrl;
      if (base.isEmpty) return false;

      if (_recent.length > 64) _recent.clear();
      _recent[key] = now;
      _sent += 1;

      final String stackText = _clip(
        stack?.toString() ?? described.stack ?? '',
        _stackLimit,
      );

      final Map<String, dynamic> payload = <String, dynamic>{
        'platform': platform,
        'appVersion': appVersion,
        'errorName': described.name,
        'errorMessage': described.message,
        'stackTrace': stackText.isEmpty ? null : stackText,
        'context': where,
        'deviceId': _deviceId,
      };

      final http.Client client = _client ?? http.Client();
      try {
        await client
            .post(
              Uri.parse('$base/api/telemetry/error'),
              headers: const <String, String>{
                'content-type': 'application/json',
              },
              body: jsonEncode(payload),
            )
            .timeout(timeout);
      } finally {
        if (_client == null) client.close();
      }
      return true;
    } catch (_) {
      // A crash reporter is never allowed to become the crash.
      return false;
    }
  }

  static const int _nameLimit = 200;
  static const int _messageLimit = 800;
  static const int _stackLimit = 4000;
  static const int _contextLimit = 200;

  static final RegExp _trailingSlashes = RegExp(r'/+$');
  static final RegExp _jwt = RegExp(
    r'eyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}',
  );
  static final RegExp _bearer = RegExp(
    r'(bearer\s+)[A-Za-z0-9._~+/\-]{8,}=*',
    caseSensitive: false,
  );
  static final RegExp _secret = RegExp(
    r'((?:password|passwd|pass|token|secret|apikey|api_key|authorization)\s*[=:]\s*)[^\s,;"}]{3,}',
    caseSensitive: false,
  );
  static final RegExp _longHex = RegExp(r'\b[0-9a-fA-F]{40,}\b');

  static String _trimSlashes(String value) =>
      value.trim().replaceAll(_trailingSlashes, '');

  static String _scrub(String input) {
    return input
        .replaceAll(_jwt, '[jwt]')
        .replaceAllMapped(_bearer, (Match m) => '${m.group(1)}[redacted]')
        .replaceAllMapped(_secret, (Match m) => '${m.group(1)}[redacted]')
        .replaceAll(_longHex, '[hex]');
  }

  static String _clip(String value, int max) {
    final String text = _scrub(value).trim();
    if (text.length <= max) return text;
    return '${text.substring(0, max - 1)}\u2026';
  }

  static _Described _describe(Object? error) {
    if (error == null) {
      return const _Described('UnknownError', 'null error', null);
    }
    final String name = _clip(error.runtimeType.toString(), _nameLimit);
    String message;
    try {
      message = _clip(error.toString(), _messageLimit);
    } catch (_) {
      message = name;
    }
    if (message.isEmpty) message = name;
    final String? stack = error is Error ? error.stackTrace?.toString() : null;
    return _Described(name.isEmpty ? 'Error' : name, message, stack);
  }
}

class _Described {
  const _Described(this.name, this.message, this.stack);

  final String name;
  final String message;
  final String? stack;
}
