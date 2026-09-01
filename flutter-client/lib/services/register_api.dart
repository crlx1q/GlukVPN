import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'api_client.dart';

/// What `GET /api/auth/config` says about sign-up right now.
class RegisterConfig {
  const RegisterConfig({
    required this.selfRegistration,
    required this.telegramEnabled,
    required this.codeTtlMinutes,
  });

  /// Optimistic default: the form renders immediately instead of flashing a
  /// "closed" state while the request is in flight. The server is asked anyway
  /// and its answer wins.
  static const RegisterConfig unknown = RegisterConfig(
    selfRegistration: true,
    telegramEnabled: true,
    codeTtlMinutes: 5,
  );

  final bool selfRegistration;

  /// Sign-up ends in the Telegram bot, so a bot that is down closes the whole
  /// flow. Saying that on step one is far better than saying it on step three.
  final bool telegramEnabled;
  final int codeTtlMinutes;

  bool get open => selfRegistration && telegramEnabled;
}

/// Where the registration ends: the deep link into the bot plus the code to
/// paste if the link cannot be opened.
class TelegramHandoff {
  const TelegramHandoff({required this.url, required this.code});

  final String url;
  final String code;

  /// `https://t.me/glukvpnbot?start=ABC` -> `@glukvpnbot`. Derived rather than
  /// hardcoded, so renaming the bot server-side needs no app release.
  String get botHandle {
    final Uri? parsed = Uri.tryParse(url);
    if (parsed == null || parsed.pathSegments.isEmpty) return '';
    final String name = parsed.pathSegments.first.trim();
    return name.isEmpty ? '' : '@$name';
  }
}

/// Public client for sign-up and password recovery.
///
/// Deliberately separate from [ApiClient]:
///
///  * none of these routes take a session, and ApiClient's transparent refresh
///    would fire on every 401 for nothing;
///  * **ROUND 10 (2.1): registration always talks to PROD.** Beta is a closed
///    deployment with its own database and self-registration switched off, so
///    an account created there could never be used from a normal build. The
///    website now follows exactly the same rule, and the two must not disagree
///    - that is how you get "I registered on my phone but the site says no
///    such account".
///
/// Password recovery is the exception and stays on the active channel: a
/// password is changed on the account you will actually sign in to.
class RegisterApi {
  RegisterApi({http.Client? httpClient})
      : _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  final http.Client _http;
  final bool _ownsClient;

  static String _trim(String url) => url.replaceAll(RegExp(r'/+$'), '');

  /// Always production, whatever channel the app is on.
  static String get registrationBase =>
      _trim(AppConfig.baseUrlFor(AppChannel.prod));

  /// Follows the dev-menu channel, because recovery belongs to the account you
  /// are going to sign in with.
  static String get recoveryBase => _trim(AppConfig.activeBaseUrl);

  void close() {
    if (_ownsClient) _http.close();
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String base,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final Uri uri = Uri.parse('$base$path');
    final http.Request request = http.Request(method, uri);
    request.headers['accept'] = 'application/json';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    http.Response response;
    try {
      final http.StreamedResponse streamed =
          await _http.send(request).timeout(AppConfig.httpTimeout);
      response = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw ApiException(
        statusCode: 0,
        code: 'timeout',
        message: 'The server did not respond in time.',
      );
    } catch (_) {
      throw ApiException(
        statusCode: 0,
        code: 'network_error',
        message: 'Cannot reach the server. Check your internet connection.',
      );
    }

    Map<String, dynamic> json = <String, dynamic>{};
    if (response.body.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(response.body);
        if (decoded is Map) json = decoded.cast<String, dynamic>();
      } catch (_) {
        json = <String, dynamic>{};
      }
    }

    if (response.statusCode >= 200 && response.statusCode < 300) return json;

    String code = 'http_${response.statusCode}';
    String message = 'Request failed (${response.statusCode}).';
    final Object? error = json['error'];
    if (error is Map) {
      final Map<String, dynamic> parsed = error.cast<String, dynamic>();
      code = (parsed['code'] ?? code).toString();
      message = (parsed['message'] ?? message).toString();
    }
    final String? retryAfter = response.headers['retry-after'];
    throw ApiException(
      statusCode: response.statusCode,
      code: code,
      message: message,
      retryAfterSec: retryAfter == null ? null : int.tryParse(retryAfter),
    );
  }

  /// Reads the sign-up policy. Never throws: a config call that fails must not
  /// be the reason a working sign-up form refuses to appear.
  Future<RegisterConfig> config() async {
    try {
      final Map<String, dynamic> json =
          await _send('GET', registrationBase, '/api/auth/config');
      final Object? telegram = json['telegram'];
      final bool telegramEnabled = telegram is Map
          ? telegram['enabled'] != false
          : true;
      final Object? ttl = json['codeTtlMinutes'];
      return RegisterConfig(
        selfRegistration: json['selfRegistration'] != false,
        telegramEnabled: telegramEnabled,
        codeTtlMinutes: ttl is num ? ttl.toInt() : 5,
      );
    } on ApiException {
      return RegisterConfig.unknown;
    }
  }

  /// Step 1. Returns true when the six-digit code was actually delivered.
  ///
  /// A false here is not an error: the account is pending either way, but the
  /// screen has to say the mail did not go out instead of leaving somebody
  /// waiting for a code that will never arrive.
  Future<bool> start({
    required String email,
    required String password,
  }) async {
    final Map<String, dynamic> json = await _send(
      'POST',
      registrationBase,
      '/api/auth/register/start',
      body: <String, dynamic>{
        'email': email,
        'password': password,
        'passwordConfirm': password,
      },
    );
    return json['delivered'] != false;
  }

  Future<void> resend(String email) => _send(
        'POST',
        registrationBase,
        '/api/auth/register/resend',
        body: <String, dynamic>{'email': email},
      );

  /// Step 2. Proves the address exists and hands back the Telegram step.
  Future<TelegramHandoff> verifyEmail({
    required String email,
    required String code,
  }) async {
    final Map<String, dynamic> json = await _send(
      'POST',
      registrationBase,
      '/api/auth/register/verify-email',
      body: <String, dynamic>{'email': email, 'code': code},
    );
    return TelegramHandoff(
      url: (json['telegramUrl'] ?? '').toString(),
      code: (json['telegramCode'] ?? '').toString(),
    );
  }

  /// Step 3 is finished inside Telegram, so the app can only ask the server
  /// whether it happened. Returns the new username once the account exists.
  Future<String?> pollStatus(String email) async {
    final Map<String, dynamic> json = await _send(
      'GET',
      registrationBase,
      '/api/auth/register/status?email=${Uri.encodeQueryComponent(email)}',
    );
    if ((json['state'] ?? '').toString() != 'done') return null;
    return (json['username'] ?? '').toString();
  }

  // --- password recovery ----------------------------------------------------

  /// Returns the channel the code was actually sent through (`email` or
  /// `telegram`), which is not always the one that was asked for.
  Future<String> forgotPassword({
    required String identifier,
    String? channel,
  }) async {
    final Map<String, dynamic> json = await _send(
      'POST',
      recoveryBase,
      '/api/auth/password/forgot',
      body: <String, dynamic>{
        'identifier': identifier,
        if (channel != null) 'channel': channel,
      },
    );
    return (json['channel'] ?? 'email').toString();
  }

  Future<void> resetPassword({
    required String identifier,
    required String code,
    required String password,
  }) =>
      _send(
        'POST',
        recoveryBase,
        '/api/auth/password/reset',
        body: <String, dynamic>{
          'identifier': identifier,
          'code': code,
          'password': password,
        },
      );
}
