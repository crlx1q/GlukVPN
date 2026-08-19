import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/models.dart';

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return <String, dynamic>{};
}

/// A failed API call, already translated into something showable to the user.
class ApiException implements Exception {
  ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.retryAfterSec,
  });

  /// HTTP status, or 0 for transport-level failures (offline, DNS, TLS, timeout).
  final int statusCode;
  final String code;
  final String message;
  final int? retryAfterSec;

  bool get isNetwork => statusCode == 0;
  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;
  bool get isConflict => statusCode == 409;
  bool get isRateLimited => statusCode == 429;

  /// The device this app registered was revoked or deleted server-side.
  bool get isDeviceRevoked =>
      isForbidden && (code == 'device_revoked' || message.toLowerCase().contains('device'));

  @override
  String toString() => message;
}

/// Typed client for the GlukVPN control plane.
///
/// Responsibilities kept here on purpose:
///  * one place that knows the URL layout and the JSON envelope
///  * transparent access-token refresh, single-flight so parallel 401s cause
///    exactly one refresh call
///  * no logging of tokens or key material anywhere
class ApiClient {
  ApiClient({http.Client? httpClient, String? baseUrl})
      : _http = httpClient ?? http.Client(),
        _baseUrl = (baseUrl ?? AppConfig.apiBaseUrl).replaceAll(RegExp(r'/+$'), '');

  final http.Client _http;
  final String _baseUrl;

  TokenBundle? _tokens;
  Future<void>? _refreshing;

  /// Fired whenever tokens are issued, rotated, or dropped. `null` means the
  /// session is gone and the UI must return to the login screen.
  void Function(TokenBundle? tokens)? onTokensChanged;

  String get baseUrl => _baseUrl;
  TokenBundle? get tokens => _tokens;
  String? get deviceId => _tokens?.deviceId;
  bool get isAuthenticated => _tokens != null;

  void setTokens(TokenBundle? tokens, {bool notify = true}) {
    _tokens = tokens;
    if (notify) onTokensChanged?.call(tokens);
  }

  void close() => _http.close();

  // --- transport -----------------------------------------------------------

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Object? body,
    bool authenticated = true,
    bool allowRefresh = true,
  }) async {
    if (authenticated && allowRefresh && (_tokens?.isExpiring ?? false)) {
      await _tryRefresh();
    }

    final Uri uri = Uri.parse('$_baseUrl$path');
    final http.Request request = http.Request(method, uri);
    request.headers['accept'] = 'application/json';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final String? accessToken = authenticated ? _tokens?.accessToken : null;
    if (accessToken != null && accessToken.isNotEmpty) {
      request.headers['authorization'] = 'Bearer $accessToken';
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
      // Deliberately does not echo the platform error: it can contain the URL
      // with query parameters, and it means nothing to the user.
      throw ApiException(
        statusCode: 0,
        code: 'network_error',
        message: 'Cannot reach the server. Check your internet connection.',
      );
    }

    // One transparent retry after a token refresh.
    if (response.statusCode == 401 && authenticated && allowRefresh && _tokens != null) {
      final bool refreshed = await _tryRefresh();
      if (refreshed) {
        return _request(method, path, body: body, authenticated: authenticated, allowRefresh: false);
      }
    }

    return _decode(response);
  }

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic> json = <String, dynamic>{};
    if (response.body.isNotEmpty) {
      try {
        json = _map(jsonDecode(response.body));
      } catch (_) {
        json = <String, dynamic>{};
      }
    }

    if (response.statusCode >= 200 && response.statusCode < 300) return json;

    String code = 'http_${response.statusCode}';
    String message = 'Request failed (${response.statusCode}).';
    final Object? error = json['error'];
    if (error is Map) {
      final Map<String, dynamic> parsed = _map(error);
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

  /// Rotates the refresh token. Concurrent callers await the same in-flight call
  /// instead of racing, which would invalidate each other's rotated token.
  Future<bool> _tryRefresh() async {
    final Future<void>? inFlight = _refreshing;
    if (inFlight != null) {
      await inFlight;
      return _tokens != null;
    }

    final TokenBundle? current = _tokens;
    if (current == null || current.refreshToken.isEmpty) return false;

    final Completer<void> completer = Completer<void>();
    _refreshing = completer.future;
    try {
      final Map<String, dynamic> json = await _request(
        'POST',
        '/api/auth/refresh',
        body: <String, dynamic>{'refreshToken': current.refreshToken},
        authenticated: false,
        allowRefresh: false,
      );
      final TokenBundle rotated = TokenBundle.fromJson(json);
      setTokens(rotated.deviceId == null ? rotated.withDeviceId(current.deviceId) : rotated);
      return true;
    } on ApiException catch (error) {
      // A rejected refresh token is terminal: force a clean logout.
      if (error.isUnauthorized || error.isForbidden) setTokens(null);
      return false;
    } finally {
      if (!completer.isCompleted) completer.complete();
      _refreshing = null;
    }
  }

  // --- health & auth -------------------------------------------------------

  Future<bool> health() async {
    final Map<String, dynamic> json =
        await _request('GET', '/api/health', authenticated: false);
    return json['ok'] == true;
  }

  Future<LoginResult> login({required String username, required String password}) async {
    final Map<String, dynamic> json = await _request(
      'POST',
      '/api/auth/login',
      body: <String, dynamic>{'username': username, 'password': password},
      authenticated: false,
    );
    final LoginResult result = LoginResult.fromJson(json);
    setTokens(result.tokens);
    return result;
  }

  /// Restores a session from a stored refresh token on app start.
  Future<bool> restoreSession(String refreshToken) async {
    setTokens(
      TokenBundle(
        accessToken: '',
        accessTokenExpiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
        refreshToken: refreshToken,
      ),
      notify: false,
    );
    final bool ok = await _tryRefresh();
    if (!ok) setTokens(null, notify: false);
    return ok;
  }

  Future<void> logout({bool allDevices = false}) async {
    final String? refreshToken = _tokens?.refreshToken;
    try {
      await _request(
        'POST',
        '/api/auth/logout',
        body: <String, dynamic>{
          if (refreshToken != null && refreshToken.isNotEmpty) 'refreshToken': refreshToken,
          if (allDevices) 'allDevices': true,
        },
      );
    } on ApiException {
      // Logging out locally must succeed even if the server call fails.
    } finally {
      setTokens(null);
    }
  }

  Future<MeResult> me() async => MeResult.fromJson(await _request('GET', '/api/auth/me'));

  // --- nodes ---------------------------------------------------------------

  Future<List<VpnNodeInfo>> nodes() async {
    final Map<String, dynamic> json = await _request('GET', '/api/nodes');
    final Object? raw = json['nodes'];
    if (raw is! List) return const <VpnNodeInfo>[];
    return raw.map((Object? item) => VpnNodeInfo.fromJson(_map(item))).toList();
  }

  Future<VpnNodeInfo> node(String nodeId) async {
    final Map<String, dynamic> json = await _request('GET', '/api/nodes/$nodeId');
    return VpnNodeInfo.fromJson(_map(json['node']));
  }

  // --- devices -------------------------------------------------------------

  /// Registers this device's **public** key and upgrades the session to
  /// device-scoped tokens.
  Future<DeviceRegistration> registerDevice({
    required String deviceName,
    required String publicKeyBase64,
    String platform = 'android',
  }) async {
    final Map<String, dynamic> json = await _request(
      'POST',
      '/api/devices/register',
      body: <String, dynamic>{
        'deviceName': deviceName,
        'publicKey': publicKeyBase64,
        'platform': platform,
      },
    );
    final DeviceRegistration registration = DeviceRegistration.fromJson(json);
    setTokens(registration.tokens);
    return registration;
  }

  Future<DevicesResult> devices() async =>
      DevicesResult.fromJson(await _request('GET', '/api/devices'));

  Future<void> revokeDevice(String deviceId) =>
      _request('DELETE', '/api/devices/$deviceId');

  // --- vpn -----------------------------------------------------------------

  Future<ConnectResult> connect({String? nodeId}) async {
    final Map<String, dynamic> json = await _request(
      'POST',
      '/api/vpn/connect',
      body: <String, dynamic>{if (nodeId != null) 'nodeId': nodeId},
    );
    return ConnectResult.fromJson(json);
  }

  Future<void> disconnect({String? sessionId}) => _request(
        'POST',
        '/api/vpn/disconnect',
        body: <String, dynamic>{if (sessionId != null) 'sessionId': sessionId},
      );

  Future<VpnStatusInfo> status() async =>
      VpnStatusInfo.fromJson(await _request('GET', '/api/vpn/status'));

  // --- egress check --------------------------------------------------------

  /// Public IP as seen from the current network path.
  ///
  /// While the tunnel is up this must report the VPN node's address: that is the
  /// proof that traffic actually egresses through the node and not through the
  /// phone's carrier. Returns null when the probe is unreachable.
  Future<String?> probeExitIp() async {
    try {
      final http.Response response = await _http
          .get(Uri.parse(AppConfig.exitIpProbeUrl))
          .timeout(AppConfig.exitIpTimeout);
      if (response.statusCode != 200) return null;
      final Object? decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['ip'] is String) return decoded['ip'] as String;
      return null;
    } catch (_) {
      return null;
    }
  }
}
