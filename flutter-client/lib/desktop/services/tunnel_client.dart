import '../../platform/tunnel_backend.dart';
import '../logic/connection_phase.dart';
import 'tunnel_ipc.dart';

/// What the service told us about itself during the handshake.
class TunnelServiceInfo {
  const TunnelServiceInfo({
    required this.serviceVersion,
    required this.protocolVersion,
    required this.driver,
    required this.splitEngine,
    required this.driverReady,
    required this.perAppRedirectSupported,
  });

  final String serviceVersion;
  final int protocolVersion;

  /// e.g. "wireguard-nt".
  final String driver;

  /// "wfp-guard" (default) or "windivert" when the optional module is built.
  final String splitEngine;

  /// False when tunnel.dll / wireguard.dll are missing from the install.
  final bool driverReady;

  /// Only true with a redirect-capable engine. Drives the honest wording in
  /// the split-tunnelling settings page.
  final bool perAppRedirectSupported;

  bool get compatible => protocolVersion == kTunnelProtocolVersion;
}

/// Windows implementation of [TunnelBackend].
///
/// Talks to GlukVpnTunnelService.exe over a named pipe. All privileged work
/// (adapter creation, routing, WFP filters) happens in that service, so the
/// Flutter process never needs to be elevated after install.
class WindowsTunnelClient implements TunnelBackend, TunnelEngineReporter {
  WindowsTunnelClient({
    TunnelPipe? pipe,
    String pipeName = 'GlukVPN.tunnel',
  }) : _pipe = pipe ?? TunnelPipe(pipeName: pipeName);

  final TunnelPipe _pipe;

  TunnelServiceInfo? _info;
  String? _lastError;
  String? _engine;

  TunnelServiceInfo? get info => _info;
  String? get lastError => _lastError;

  /// ROUND 26: `sing-box` or `wireguard`, from the `engine` field the service
  /// adds to every status reply. Null until the service has said, or with a
  /// service from before the field existed. Kept here rather than on
  /// [TunnelSnapshot] because that type is shared with Android, which has no
  /// engine to report.
  @override
  String? get reportedEngine => _engine;

  /// Remembers the engine named in [payload], if any.
  void _noteEngine(Map<String, dynamic>? payload) {
    final Object? raw = payload?['engine'];
    if (raw is String && raw.isNotEmpty) _engine = raw;
  }

  @override
  Future<bool> isAvailable() async {
    final info = await hello();
    return info != null && info.compatible;
  }

  /// Handshake. Cached unless [force] is set.
  Future<TunnelServiceInfo?> hello({bool force = false}) async {
    if (_info != null && !force) return _info;

    final reply = await _pipe.send(<String, dynamic>{
      'op': 'hello',
      'v': kTunnelProtocolVersion,
    });

    if (!reply.ok) {
      _lastError = reply.errorCode;
      _info = null;
      return null;
    }

    final payload = reply.payload!;
    if (payload['ok'] != true) {
      _lastError = _errorCodeOf(payload);
      _info = null;
      return null;
    }

    _info = TunnelServiceInfo(
      serviceVersion: (payload['serviceVersion'] as String?) ?? '0.0.0',
      protocolVersion: _asInt(payload['protocolVersion']) ?? 0,
      driver: (payload['driver'] as String?) ?? 'unknown',
      splitEngine: (payload['splitEngine'] as String?) ?? 'wfp-guard',
      driverReady: payload['driverReady'] == true,
      perAppRedirectSupported: payload['perAppRedirect'] == true,
    );
    _noteEngine(payload);
    _lastError = null;
    return _info;
  }

  @override
  Future<TunnelResult> up({
    required String wgConf,
    required String sessionId,
    TunnelUpOptions options = const TunnelUpOptions(),
  }) async {
    final reply = await _pipe.send(<String, dynamic>{
      'op': 'up',
      'v': kTunnelProtocolVersion,
      'sessionId': sessionId,
      'adapter': options.adapterName,
      'conf': wgConf,
      'killSwitch': options.killSwitch,
      'dns': options.dns,
      if (options.mtu != null) 'mtu': options.mtu,
      // ROUND 24: flat keys, because those are the ones the service reads.
      // The nested "split" object sent here before was silently ignored, so
      // no split mode and no bypass route has ever reached the tunnel - and
      // sing-box needs the bypass prefixes to keep the LAN out of the TUN.
      'splitMode': splitModeWire(options.splitMode),
      'splitApps': options.splitApps,
      'bypassRoutes': options.bypassRoutes,
      'endpointIps': options.endpointIps,
      // Present only when the node advertised a TLS gateway. That is what
      // makes the service start sing-box instead of the WireGuard worker.
      if (options.gateway != null) 'gateway': options.gateway!.toWire(),
    });

    return _resultFrom(reply);
  }

  @override
  Future<TunnelResult> down() async {
    final reply = await _pipe.send(<String, dynamic>{
      'op': 'down',
      'v': kTunnelProtocolVersion,
    });
    return _resultFrom(reply);
  }

  @override
  Future<TunnelSnapshot> status() async {
    final reply = await _pipe.send(<String, dynamic>{
      'op': 'status',
      'v': kTunnelProtocolVersion,
    });

    if (!reply.ok) {
      return TunnelSnapshot(
        state: _stateForTransportError(reply.errorCode),
        errorCode: reply.errorCode,
        errorMessage: reply.errorMessage,
      );
    }

    _noteEngine(reply.payload);
    return parseStatus(reply.payload!);
  }

  @override
  Future<TunnelResult> setSplit({
    required SplitMode mode,
    List<String> apps = const <String>[],
    List<String> bypassRoutes = const <String>[],
  }) async {
    final reply = await _pipe.send(<String, dynamic>{
      'op': 'set-split',
      'v': kTunnelProtocolVersion,
      'mode': splitModeWire(mode),
      'apps': apps,
      'bypassRoutes': bypassRoutes,
    });
    return _resultFrom(reply);
  }

  @override
  Future<void> dispose() async {
    _info = null;
  }

  // ---------------------------------------------------------------------

  TunnelResult _resultFrom(PipeReply reply) {
    if (!reply.ok) {
      return TunnelResult.failure(
        reply.errorCode,
        reply.errorMessage,
        snapshot: TunnelSnapshot(
          state: _stateForTransportError(reply.errorCode),
          errorCode: reply.errorCode,
          errorMessage: reply.errorMessage,
        ),
      );
    }

    final payload = reply.payload!;
    _noteEngine(payload);
    if (payload['ok'] != true) {
      final code = _errorCodeOf(payload);
      return TunnelResult.failure(
        code,
        _errorMessageOf(payload),
        snapshot: parseStatus(payload).copyWith(
          state: TunnelState.error,
          errorCode: code,
        ),
      );
    }

    return TunnelResult.ok(parseStatus(payload));
  }

  /// Converts a status reply body into a snapshot.
  ///
  /// Static and side-effect free so tests can exercise it with literal maps.
  static TunnelSnapshot parseStatus(Map<String, dynamic> body) {
    return TunnelSnapshot(
      state: _parseState(body['state'] as String?),
      sessionId: body['sessionId'] as String?,
      adapterName: body['adapter'] as String?,
      luid: _asInt(body['luid']),
      vpnIp: body['vpnIp'] as String?,
      rxBytes: _asInt(body['rxBytes']) ?? 0,
      txBytes: _asInt(body['txBytes']) ?? 0,
      lastHandshakeUnix: _asInt(body['lastHandshakeUnix']) ?? 0,
      sinceUnix: _asInt(body['since']) ?? 0,
      killSwitchActive: body['killSwitch'] == true,
      splitEngine: body['splitEngine'] as String?,
      errorCode: _errorCodeOf(body),
      errorMessage: _errorMessageOf(body),
    );
  }

  static TunnelState _parseState(String? raw) {
    switch (raw) {
      case 'connected':
        return TunnelState.connected;
      case 'starting':
        return TunnelState.connecting;
      case 'down':
        return TunnelState.disconnected;
      case 'lost':
        // A dropped tunnel is still "connected" from the adapter's point of
        // view; the verifier decides via handshake age. Report it as an
        // error state so the controller can react immediately.
        return TunnelState.error;
      case 'error':
        return TunnelState.error;
      default:
        return TunnelState.unknown;
    }
  }

  static TunnelState _stateForTransportError(String? code) {
    switch (code) {
      case 'service_unavailable':
        return TunnelState.unavailable;
      case 'pipe_denied':
        return TunnelState.denied;
      default:
        return TunnelState.unavailable;
    }
  }

  // The service uses two shapes: a rejected request answers with a nested
  // `error: {code, message}` object, while a status body that describes a
  // tunnel that failed on its own carries flat `errorCode` / `errorMessage`
  // keys (FillStatus in pipe_server.cpp). ROUND 26: both are read, so the
  // service's own explanation - "sing-box.exe is missing next to the service"
  // - reaches the UI instead of a bare tunnel_error.

  static String? _errorCodeOf(Map<String, dynamic> body) {
    final error = body['error'];
    if (error is Map) return error['code'] as String?;
    final flat = body['errorCode'];
    if (flat is String && flat.isNotEmpty) return flat;
    return null;
  }

  static String? _errorMessageOf(Map<String, dynamic> body) {
    final error = body['error'];
    if (error is Map) return error['message'] as String?;
    final flat = body['errorMessage'];
    if (flat is String && flat.isNotEmpty) return flat;
    return null;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
