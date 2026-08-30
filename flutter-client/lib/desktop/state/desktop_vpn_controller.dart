import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../config.dart';
import '../../models/models.dart';
import '../../platform/tunnel_backend.dart';
import '../../services/api_client.dart';
import '../../services/ping_service.dart';
import '../../state/auth_controller.dart';
import '../logic/connection_phase.dart';
import '../logic/node_selector.dart';
import '../services/tunnel_client.dart';
import 'desktop_settings.dart';
import 'usage_store.dart';

/// Orchestrates the whole desktop connect lifecycle.
///
/// Design rules baked in here:
///  * The Windows tunnel is the source of truth. The UI mirrors it; it never
///    invents a state the tunnel does not have.
///  * CONNECTED is only published after [TunnelVerifier] agrees — this is the
///    fix for the premature-CONNECTED bug on Android.
///  * The control API going away never tears down a healthy tunnel.
///  * Closing the window does not touch this controller at all.
class DesktopVpnController extends ChangeNotifier {
  DesktopVpnController({
    required ApiClient api,
    required AuthController auth,
    required TunnelBackend tunnel,
    required SettingsStore settings,
    required UsageStore usage,
    PingService? ping,
    TunnelVerifier? verifier,
  })  : _api = api,
        _auth = auth,
        _tunnel = tunnel,
        _settings = settings,
        _usage = usage,
        _ping = ping ?? PingService(),
        _verifier = verifier ??
            TunnelVerifier(handshakeStaleAfter: AppConfig.handshakeStaleAfter);

  final ApiClient _api;
  final AuthController _auth;
  final TunnelBackend _tunnel;
  final SettingsStore _settings;
  final UsageStore _usage;
  final PingService _ping;
  final TunnelVerifier _verifier;

  // ---- published state ----
  ConnectionPhase _phase = ConnectionPhase.disconnected;
  String _statusDetail = '';
  String? _userMessage;
  TunnelSnapshot _snapshot = TunnelSnapshot.unknown;
  List<VpnNodeInfo> _nodes = const <VpnNodeInfo>[];
  VpnNodeInfo? _selectedNode;
  AutoNodeChoice? _autoSelection;
  final Map<String, int> _pings = <String, int>{};
  int? _currentPingMs;
  PingSource _pingSource = PingSource.none;
  String? _publicIp;
  VpnSessionInfo? _session;
  bool _serviceReady = false;
  DateTime? _connectedSince;

  // ---- internals ----
  Timer? _statusTimer;
  Timer? _serverTimer;
  Timer? _pingTimer;
  Timer? _connectDeadline;
  bool _busy = false;
  bool _disposed = false;
  int _baselineRx = 0;
  bool _dataObserved = false;
  bool _reconnectAttempted = false;
  String? _activeSessionId;
  List<String> _activeEndpointIps = const <String>[];

  // ---- getters ----
  ConnectionPhase get phase => _phase;
  String get statusDetail => _statusDetail;
  String? get userMessage => _userMessage;
  TunnelSnapshot get snapshot => _snapshot;
  List<VpnNodeInfo> get nodes => _nodes;
  VpnNodeInfo? get selectedNode => _selectedNode;
  AutoNodeChoice? get autoSelection => _autoSelection;
  Map<String, int> get pings => Map<String, int>.unmodifiable(_pings);
  int? get currentPingMs => _currentPingMs;
  PingSource get pingSource => _pingSource;
  String? get publicIp => _publicIp;
  VpnSessionInfo? get session => _session;
  SubscriptionInfo? get subscription => _auth.subscription;
  bool get serviceReady => _serviceReady;
  int get rxBytes => _snapshot.rxBytes;
  int get txBytes => _snapshot.txBytes;
  UsageSnapshot get usage => _usage.snapshot();

  /// Visible list, with internal nodes stripped for production builds.
  List<VpnNodeInfo> get userVisibleNodes =>
      visibleNodes(_nodes, internalBuild: AppConfig.internalBuild);

  bool get autoSelectionEnabled => _settings.value.autoNodeSelection;

  Duration? get connectedFor {
    final since = _connectedSince;
    if (since == null) return null;
    return DateTime.now().difference(since);
  }

  // -------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------

  /// Called once at startup, after the window is already visible.
  ///
  /// Everything here is deliberately non-blocking so the UI appears fast
  /// (requirement 3).
  Future<void> bootstrap() async {
    _serviceReady = await _tunnel.isAvailable();
    _notify();

    // Adopt whatever the service is already doing (requirement 12: the UI can
    // be closed and reopened while the tunnel keeps running).
    await adopt();

    unawaited(refreshNodes());
    _startStatusPolling();

    if (_settings.value.autoConnect &&
        _phase == ConnectionPhase.disconnected &&
        _auth.stage == AuthStage.authenticated) {
      unawaited(connect());
    }
  }

  /// Reads live state from the service and republishes it without changing
  /// anything. This is what makes reopening the window instant and correct.
  Future<void> adopt() async {
    final snap = await _tunnel.status();
    _snapshot = snap;
    _activeSessionId = snap.sessionId;

    if (snap.state == TunnelState.connected) {
      _baselineRx = snap.rxBytes;
      _dataObserved = snap.rxBytes > 0;
      final since = snap.uptime(DateTime.now().toUtc());
      if (since != null) {
        _connectedSince = DateTime.now().subtract(since);
      }
      _usage.beginSession();
    }

    await _reevaluate(fetchServerStatus: true);
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(AppConfig.serviceStatusInterval, (_) {
      unawaited(_pollTunnel());
    });

    _serverTimer?.cancel();
    _serverTimer = Timer.periodic(AppConfig.statusPollInterval, (_) {
      if (_phase.isConnected || _phase == ConnectionPhase.connecting) {
        unawaited(refreshServerStatus());
      }
    });

    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(AppConfig.pingInterval, (_) {
      if (_phase.isConnected) unawaited(_measureLivePing());
    });
  }

  // -------------------------------------------------------------------
  // Connect / disconnect
  // -------------------------------------------------------------------

  Future<void> connect({VpnNodeInfo? node}) async {
    if (_busy) return;
    _busy = true;
    _reconnectAttempted = false;

    try {
      _setPhase(ConnectionPhase.connecting, detail: 'preparing');
      _userMessage = null;

      if (!_serviceReady) {
        _serviceReady = await _tunnel.isAvailable();
        if (!_serviceReady) {
          _fail(
            ConnectionPhase.connectionFailed,
            'tunnel_service_unavailable',
            'The GlukVPN tunnel service is not running.',
          );
          return;
        }
      }

      // Make sure this machine is a registered device before asking for a
      // peer. Windows occupies exactly one device slot (requirement 17).
      try { await _auth.ensureDeviceRegistered(); } catch (_) {
        _fail(
          ConnectionPhase.limitReached,
          'device_registration_failed',
          'Could not register this PC as a device.',
        );
        return;
      }

      final target = node ?? await _resolveTargetNode();
      if (target == null) {
        _fail(
          ConnectionPhase.serverUnavailable,
          'no_available_nodes',
          'No servers are available right now.',
        );
        return;
      }
      _selectedNode = target;

      ConnectResult result;
      try {
        result = await _api.connect(nodeId: target.id);
      } on ApiException catch (e) {
        _fail(
          phaseForApiError(
            statusCode: e.statusCode,
            code: e.code,
            refreshFailed: e.isUnauthorized,
          ),
          e.code ?? 'api_error',
          e.message,
        );
        return;
      } catch (e) {
        _fail(ConnectionPhase.connectionFailed, 'connect_failed', e.toString());
        return;
      }

      final privateKey = await _auth.readTunnelPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        _fail(
          ConnectionPhase.connectionFailed,
          'missing_private_key',
          'The tunnel key for this device is missing. Sign out and back in.',
        );
        return;
      }

      final conf = result.tunnel.toWgQuickConfig(privateKeyBase64: privateKey);
      _activeSessionId = result.session.id;
      _activeEndpointIps = _endpointHostsOf(result.tunnel);

      final settings = _settings.value;
      final options = TunnelUpOptions(
        adapterName: AppConfig.desktopAdapterName,
        killSwitch: settings.killSwitch,
        dns: settings.dns.isNotEmpty ? settings.dns : result.tunnel.dns,
        mtu: settings.mtu,
        splitMode: settings.splitMode,
        splitApps: settings.splitApps,
        endpointIps: _activeEndpointIps,
      );

      _setPhase(ConnectionPhase.connecting, detail: 'bringing_up');
      _armConnectDeadline();

      final up = await _tunnel.up(
        wgConf: conf,
        sessionId: result.session.id,
        options: options,
      );

      if (!up.ok) {
        _fail(
          ConnectionPhase.connectionFailed,
          up.errorCode ?? 'tunnel_up_failed',
          up.errorMessage,
        );
        // Release the server-side peer so we do not leak a session.
        unawaited(_releaseServerSession());
        return;
      }

      _snapshot = up.snapshot ?? _snapshot;
      _baselineRx = _snapshot.rxBytes;
      _dataObserved = false;
      _usage.beginSession();

      await _settings.update(
        (DesktopSettings s) => s.copyWith(lastNodeId: target.id),
      );

      await _reevaluate(fetchServerStatus: true);
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> disconnect({bool userInitiated = true}) async {
    if (_busy) return;
    _busy = true;

    try {
      _cancelConnectDeadline();
      _setPhase(ConnectionPhase.disconnecting, detail: 'tearing_down');

      final down = await _tunnel.down();
      _snapshot = down.snapshot ?? TunnelSnapshot.down;

      await _releaseServerSession();

      _usage.endSession();
      unawaited(_usage.flush());

      _connectedSince = null;
      _currentPingMs = null;
      _pingSource = PingSource.none;
      _dataObserved = false;
      _activeSessionId = null;
      _session = null;

      _setPhase(ConnectionPhase.disconnected, detail: 'down');
      if (userInitiated) _userMessage = null;

      unawaited(_refreshPublicIp());
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> toggle() async {
    if (_phase.isConnected) {
      await disconnect();
    } else if (!_phase.isBusy) {
      await connect();
    }
  }

  /// Switches servers without leaving the user on a dead tunnel.
  Future<void> switchNode(VpnNodeInfo node) async {
    if (_phase.isConnected || _phase == ConnectionPhase.connecting) {
      await disconnect(userInitiated: false);
    }
    await _settings.update(
      (DesktopSettings s) =>
          s.copyWith(autoNodeSelection: false, lastNodeId: node.id),
    );
    await connect(node: node);
  }

  Future<void> setAutoSelection(bool enabled) async {
    await _settings.update(
      (DesktopSettings s) => s.copyWith(autoNodeSelection: enabled),
    );
    if (enabled) {
      _autoSelection = pickBestNode(
        _nodes,
        pings: _pings,
        internalBuild: AppConfig.internalBuild,
        preferCountryCode: _auth.user?.originCountryCode,
      );
      _selectedNode = _autoSelection?.node;
    }
    _notify();
  }

  // -------------------------------------------------------------------
  // Polling and verification
  // -------------------------------------------------------------------

  Future<void> _pollTunnel() async {
    if (_disposed || _busy) return;
    _snapshot = await _tunnel.status();

    if (_snapshot.rxBytes > _baselineRx) _dataObserved = true;

    if (_phase.isConnected || _phase == ConnectionPhase.connecting) {
      _usage.sample(
        cumulativeRx: _snapshot.rxBytes,
        cumulativeTx: _snapshot.txBytes,
      );
    }

    await _reevaluate(fetchServerStatus: false);
  }

  Future<void> refreshServerStatus() async {
    if (_disposed) return;
    try {
      final status = await _api.status();
      _session = status.session;
      _lastServerStatus = ServerTunnelStatus(
        peerReady: status.peerReady,
        subscriptionActive: status.subscriptionActive,
      );
      _serverStatusFailures = 0;
    } on ApiException catch (e) {
      // Auth problems are real; transport problems are not the tunnel's fault.
      if (e.isUnauthorized || e.isForbidden) {
        final mapped = phaseForApiError(statusCode: e.statusCode, code: e.code);
        if (mapped.requiresReauth || mapped == ConnectionPhase.accessRevoked) {
          _fail(mapped, e.code ?? 'auth_error', e.message);
          await _tunnel.down();
          return;
        }
      }
      _serverStatusFailures++;
      if (_serverStatusFailures >= 3) _lastServerStatus = null;
    } catch (_) {
      _serverStatusFailures++;
      if (_serverStatusFailures >= 3) _lastServerStatus = null;
    }
    await _reevaluate(fetchServerStatus: false);
  }

  ServerTunnelStatus? _lastServerStatus;
  int _serverStatusFailures = 0;

  Future<void> _reevaluate({required bool fetchServerStatus}) async {
    if (fetchServerStatus) {
      await refreshServerStatus();
      return;
    }

    final verdict = _verifier.evaluate(
      snapshot: _snapshot,
      serverStatus: _lastServerStatus,
      dataObserved: _dataObserved,
      now: DateTime.now().toUtc(),
    );

    // A dropped tunnel gets exactly one silent reconnect attempt before we
    // bother the user.
    if (verdict.phase == ConnectionPhase.tunnelLost && !_reconnectAttempted) {
      _reconnectAttempted = true;
      _setPhase(ConnectionPhase.connecting, detail: 'auto_reconnect');
      unawaited(_autoReconnect());
      return;
    }

    if (verdict.phase == ConnectionPhase.connected) {
      _cancelConnectDeadline();
      _connectedSince ??= DateTime.now();
      _reconnectAttempted = false;
      if (_publicIp == null) unawaited(_refreshPublicIp());
    }

    _setPhase(verdict.phase, detail: verdict.reason);
  }

  Future<void> _autoReconnect() async {
    final node = _selectedNode;
    await _tunnel.down();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await connect(node: node);
  }

  void _armConnectDeadline() {
    _cancelConnectDeadline();
    _connectDeadline = Timer(AppConfig.connectTimeout, () {
      if (_phase == ConnectionPhase.connecting) {
        _fail(
          ConnectionPhase.connectionFailed,
          'connect_timeout',
          'The tunnel did not come up in time.',
        );
        unawaited(_tunnel.down());
        unawaited(_releaseServerSession());
      }
    });
  }

  void _cancelConnectDeadline() {
    _connectDeadline?.cancel();
    _connectDeadline = null;
  }

  // -------------------------------------------------------------------
  // Nodes, pings, IP
  // -------------------------------------------------------------------

  Future<void> refreshNodes() async {
    try {
      final list = await _api.nodes();
      _nodes = list;

      final remembered = _settings.value.lastNodeId;
      if (_settings.value.autoNodeSelection || remembered == null) {
        _autoSelection = pickBestNode(
          _nodes,
          pings: _pings,
          internalBuild: AppConfig.internalBuild,
          preferCountryCode: _auth.user?.originCountryCode,
        );
        _selectedNode ??= _autoSelection?.node;
      } else {
        _selectedNode = _nodes.where((VpnNodeInfo n) => n.id == remembered).firstOrNull ??
            _selectedNode;
      }

      _notify();
      unawaited(measureNodePings());
    } catch (_) {
      // Keep whatever list we already have; the UI shows a stale-data hint.
    }
  }

  /// Measures latency to visible nodes so Auto has real data to work with.
  Future<void> measureNodePings() async {
    final targets = userVisibleNodes
        .where((VpnNodeInfo n) => n.online && n.latencyHost != null)
        .take(12)
        .toList();

    for (final node in targets) {
      if (_disposed) return;
      final host = node.latencyHost;
      if (host == null) continue;
      final ms = await _ping.probeHost(host);
      if (ms != null && ms.ok) _pings[node.id] = ms.milliseconds!;
    }

    if (_settings.value.autoNodeSelection) {
      _autoSelection = pickBestNode(
        _nodes,
        pings: _pings,
        internalBuild: AppConfig.internalBuild,
        preferCountryCode: _auth.user?.originCountryCode,
      );
    }
    _notify();
  }

  Future<void> _measureLivePing() async {
    final gateway = _snapshot.vpnIp;
    final sample = await _ping.measure(
      gatewayIp: gateway,
      apiBaseUrl: AppConfig.activeBaseUrl,
    );
    _currentPingMs = sample.milliseconds;
    _pingSource = sample.source;
    // Reaching the gateway is independent proof the tunnel carries traffic.
    if (sample.source == PingSource.tunnelGateway && sample.milliseconds != null) {
      _dataObserved = true;
    }
    _notify();
  }

  Future<void> _refreshPublicIp() async {
    try {
      _publicIp = await _api.probeExitIp();
    } catch (_) {
      _publicIp = null;
    }
    _notify();
  }

  Future<VpnNodeInfo?> _resolveTargetNode() async {
    if (_nodes.isEmpty) await refreshNodes();

    final settings = _settings.value;
    final paid = manualSelectionAllowed(_auth.subscription);

    // Free accounts always get Auto (requirement 8).
    if (!paid || settings.autoNodeSelection) {
      final choice = pickBestNode(
        _nodes,
        pings: _pings,
        internalBuild: AppConfig.internalBuild,
        preferCountryCode: _auth.user?.originCountryCode,
      );
      _autoSelection = choice;
      return choice.node;
    }

    final remembered = settings.lastNodeId;
    if (remembered != null) {
      final match =
          userVisibleNodes.where((VpnNodeInfo n) => n.id == remembered).firstOrNull;
      if (match != null && match.online && match.connectable) return match;
    }

    return pickBestNode(
      _nodes,
      pings: _pings,
      internalBuild: AppConfig.internalBuild,
      preferCountryCode: _auth.user?.originCountryCode,
    ).node;
  }

  // -------------------------------------------------------------------
  // Split tunnelling
  // -------------------------------------------------------------------

  /// Applies the current split settings to a live tunnel where possible.
  ///
  /// Returns null on success, or a message explaining why a reconnect is
  /// needed. Changing to or from "all apps" alters how the adapter itself is
  /// created, so it cannot be done in place.
  Future<String?> applySplitTunneling() async {
    final settings = _settings.value;

    if (!_phase.isConnected) return null;

    final result = await _tunnel.setSplit(
      mode: settings.splitMode,
      apps: settings.splitApps,
    );

    if (result.ok) return null;

    if (result.errorCode == 'reconnect_required') {
      return 'reconnect_required';
    }
    return result.errorMessage ?? result.errorCode;
  }

  // -------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------

  Future<void> _releaseServerSession() async {
    final id = _activeSessionId;
    if (id == null) return;
    _activeSessionId = null;
    try {
      await _api.disconnect(sessionId: id);
    } catch (_) {
      // The server reaps stale sessions on its own; nothing to do here.
    }
  }

  /// Extracts the endpoint host so the kill switch can whitelist it.
  List<String> _endpointHostsOf(TunnelConfig config) {
    final endpoint = config.endpoint;
    if (endpoint.isEmpty) return const <String>[];
    final colon = endpoint.lastIndexOf(':');
    final host = colon > 0 ? endpoint.substring(0, colon) : endpoint;
    return <String>[host];
  }

  void _setPhase(ConnectionPhase next, {String detail = ''}) {
    if (_phase == next && _statusDetail == detail) return;
    _phase = next;
    _statusDetail = detail;
    _notify();
  }

  void _fail(ConnectionPhase phase, String detail, String? message) {
    _cancelConnectDeadline();
    _phase = phase;
    _statusDetail = detail;
    _userMessage = message;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Graceful shutdown from the tray Exit action.
  Future<void> shutdown({required bool disconnectTunnel}) async {
    _statusTimer?.cancel();
    _serverTimer?.cancel();
    _pingTimer?.cancel();
    _cancelConnectDeadline();

    if (disconnectTunnel && _phase.isConnected) {
      await _tunnel.down();
      await _releaseServerSession();
    }

    _usage.endSession();
    await _usage.flush(force: true);
  }

  @override
  void dispose() {
    _disposed = true;
    _statusTimer?.cancel();
    _serverTimer?.cancel();
    _pingTimer?.cancel();
    _cancelConnectDeadline();
    super.dispose();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}

