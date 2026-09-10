// Honest per-direction counters and a real in-tunnel latency, read from the
// running engine instead of from Windows.
//
// Why this file exists at all: the Windows interface table cannot answer "how
// much did I download". Our TUN inbound runs with `stack: "mixed"`, so the TCP
// half is handled by the system stack and every payload byte crosses the
// adapter twice - once leaving the application, once when sing-box re-injects
// it for the OS to pick up. `GetIfEntry2` therefore reports
// `InOctets == OutOctets == total`, which is exactly the "855 KB in / 854 KB
// out" the stats panel kept showing. It was never an inverted mapping; the
// source genuinely cannot tell the directions apart.
//
// sing-box can, and its Clash API is the only place it says so. The same API
// dials a test URL *through* the proxy outbound, which is the measurement the
// "ping - tunnel" cell always claimed to be showing while ICMP was being sent
// to the node off-tunnel.
//
// The controller is bound to 127.0.0.1 on a port the privileged service
// reserves per session, and it is closed by a per-session secret; both arrive
// over the service's own ACL'd pipe (see `SingBoxOptions::clashPort`). Every
// call here is best-effort: on any failure the caller keeps the source of
// truth it had, which is the interface counters.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Tag of the proxy outbound in the generated configuration.
///
/// Must match `ProxyOutbound` in `native/glukvpn-tunnel-service/src/singbox.cpp`.
/// A delay probe against any other tag would measure the wrong path, and
/// against a tag that does not exist it would simply 404.
const String kProxyOutboundTag = 'proxy';

/// Where the running engine's own metrics API can be reached.
class TunnelMetricsEndpoint {
  const TunnelMetricsEndpoint({required this.port, required this.secret});

  /// Loopback port. 0 means the service could not reserve one, or the engine
  /// is the WireGuard worker, which has no such API.
  final int port;

  /// Bearer token for that port. Empty when the controller is open.
  final String secret;

  bool get usable => port > 0;

  Uri uri(String path, [Map<String, String>? query]) =>
      Uri.http('127.0.0.1:$port', path, query);

  @override
  bool operator ==(Object other) =>
      other is TunnelMetricsEndpoint &&
      other.port == port &&
      other.secret == secret;

  @override
  int get hashCode => Object.hash(port, secret);

  // Deliberately does not print the secret.
  @override
  String toString() => 'TunnelMetricsEndpoint(127.0.0.1:$port)';
}

/// Implemented by backends whose engine keeps its own byte counters.
///
/// Kept apart from `TunnelBackend` for the same reason as
/// [TunnelEngineReporter]: the platform-neutral interface in `lib/platform/`
/// should not grow a Windows-only notion, and Android has no such API.
abstract class TunnelMetricsReporter {
  /// Endpoint for the live session, or null when there is nothing to poll.
  TunnelMetricsEndpoint? get reportedMetricsEndpoint;
}

/// Cumulative bytes the engine has moved this session, per direction.
class TunnelTraffic {
  const TunnelTraffic({required this.downloadBytes, required this.uploadBytes});

  final int downloadBytes;
  final int uploadBytes;

  @override
  String toString() => 'TunnelTraffic(down=$downloadBytes, up=$uploadBytes)';
}

/// Thin read-only client for sing-box's Clash API.
class ClashMetricsClient {
  ClashMetricsClient({
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 3),
  }) : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// Cap on every request. The controller is on loopback, so anything slower
  /// than this means the engine is gone rather than busy.
  final Duration timeout;

  /// Session totals, or null when the controller did not answer.
  ///
  /// `/connections` carries `downloadTotal` and `uploadTotal` alongside the
  /// list of live connections. They are counted where the two directions are
  /// still distinguishable, which is the whole point of asking.
  Future<TunnelTraffic?> traffic(TunnelMetricsEndpoint endpoint) async {
    final Map<String, dynamic>? body = await _get(endpoint, 'connections');
    if (body == null) return null;

    final int? down = _asInt(body['downloadTotal']);
    final int? up = _asInt(body['uploadTotal']);
    if (down == null || up == null) return null;

    return TunnelTraffic(downloadBytes: down, uploadBytes: up);
  }

  /// Round trip through the proxy outbound in milliseconds, or null.
  ///
  /// sing-box opens the request on the outbound itself, so a reply proves both
  /// that the tunnel carries traffic and how long a round trip through it
  /// takes. [testUrl] answers 204 with an empty body, so the probe costs a few
  /// hundred bytes of the user's allowance per sample.
  Future<int?> proxyDelay(
    TunnelMetricsEndpoint endpoint, {
    String testUrl = 'http://www.gstatic.com/generate_204',
    Duration probeTimeout = const Duration(seconds: 3),
  }) async {
    final Map<String, dynamic>? body = await _get(
      endpoint,
      'proxies/$kProxyOutboundTag/delay',
      <String, String>{
        'url': testUrl,
        'timeout': probeTimeout.inMilliseconds.toString(),
      },
    );
    if (body == null) return null;

    final int? delay = _asInt(body['delay']);
    // 0 back from the controller means "did not get there", not "instant".
    if (delay == null || delay <= 0) return null;
    return delay;
  }

  Future<Map<String, dynamic>?> _get(
    TunnelMetricsEndpoint endpoint,
    String path, [
    Map<String, String>? query,
  ]) async {
    if (!endpoint.usable) return null;

    try {
      final http.Response response = await _http
          .get(
            endpoint.uri(path, query),
            headers: <String, String>{
              if (endpoint.secret.isNotEmpty)
                'Authorization': 'Bearer ${endpoint.secret}',
            },
          )
          .timeout(timeout);
      if (response.statusCode != 200) return null;

      final Object? decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      // The controller has not finished binding, the session ended, or the
      // reserved port was taken by something else between reserving it and
      // sing-box binding it. All three mean the same thing to the caller.
      return null;
    }
  }

  static int? _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.round();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  void close() => _http.close();
}
