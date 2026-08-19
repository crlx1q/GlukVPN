import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../services/ping_service.dart';
import '../services/vpn_service.dart';
import 'auth_controller.dart';

enum VpnUiState { disconnected, connecting, connected, disconnecting }

/// Drives the connect/disconnect flow and everything the Home screen shows.
///
/// The order of operations is deliberate and mirrors the documented flow:
/// register public key -> ask control plane for a session (it tells the node to
/// add the peer) -> raise the local tunnel -> poll session state for traffic.
class VpnController extends ChangeNotifier {
  VpnController({
    required ApiClient api,
    required VpnService vpn,
    required PingService ping,
    required AuthController auth,
  })  : _api = api,
        _vpn = vpn,
        _pingService = ping,
        _auth = auth;

  final ApiClient _api;
  final VpnService _vpn;
  final PingService _pingService;
  final AuthController _auth;

  StreamSubscription<TunnelStage>? _stageSubscription;
  Timer? _statusTimer;
  Timer? _pingTimer;
  Timer? _tickTimer;
  Timer? _watchdog;

  List<VpnNodeInfo> _nodes = const <VpnNodeInfo>[];
  VpnNodeInfo? _selectedNode;
  VpnUiState _state = VpnUiState.disconnected;
  TunnelStage _tunnelStage = TunnelStage.unknown;
  VpnSessionInfo? _session;
  TunnelConfig? _tunnel;
  String? _exitIp;
  PingSample _pingSample = const PingSample.empty();
  String? _error;
  String? _notice;
  bool _loadingNodes = false;
  bool _busy = false;
  bool _peerReady = false;
  bool _disposed = false;
  DateTime? _connectedSince;
  Duration _connectedFor = Duration.zero;

  List<VpnNodeInfo> get nodes => _nodes;
  VpnNodeInfo? get selectedNode => _selectedNode;
  VpnUiState get state => _state;
  TunnelStage get tunnelStage => _tunnelStage;
  VpnSessionInfo? get session => _session;
  TunnelConfig? get tunnel => _tunnel;
  String? get exitIp => _exitIp;
  PingSample get ping => _pingSample;
  String? get error => _error;
  String? get notice => _notice;
  bool get loadingNodes => _loadingNodes;
  bool get busy => _busy;
  bool get peerReady => _peerReady;
  Duration get connectedFor => _connectedFor;

  bool get isConnected => _state == VpnUiState.connected;
  bool get isTransitioning =>
      _state == VpnUiState.connecting || _state == VpnUiState.disconnecting;

  int get bytesRx => _session?.bytesRx ?? 0;
  int get bytesTx => _session?.bytesTx ?? 0;
  String? get assignedIp => _session?.assignedVpnIp ?? _tunnel?.assignedIp;

  String get statusLabel {
    switch (_state) {
      case VpnUiState.disconnected:
        return 'Disconnected';
      case VpnUiState.connecting:
        return 'Connecting';
      case VpnUiState.connected:
        return 'Connected';
      case VpnUiState.disconnecting:
        return 'Disconnecting';
    }
  }

  void clearMessages() {
    if (_error == null && _notice == null) return;
    _error = null;
    _notice = null;
    _safeNotify();
  }

  // --- lifecycle -----------------------------------------------------------

  Future<void> init() async {
    _stageSubscription ??= _vpn.stages.listen(_onStage);
    try {
      await _vpn.initialize();
    } catch (error) {
      _error = 'The VPN engine could not be initialised: $error';
    }
    await loadNodes();
    await _syncWithServer(initial: true);
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTimers();
    _stageSubscription?.cancel();
    _stageSubscription = null;
    super.dispose();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // --- nodes ---------------------------------------------------------------

  Future<void> loadNodes() async {
    _loadingNodes = true;
    _safeNotify();
    try {
      final List<VpnNodeInfo> loaded = await _api.nodes();
      _nodes = loaded;

      final String? currentId = _selectedNode?.id;
      VpnNodeInfo? next;
      if (currentId != null) {
        next = _firstOrNull(loaded.where((VpnNodeInfo n) => n.id == currentId));
      }
      next ??= _firstOrNull(loaded.where((VpnNodeInfo n) => n.connectable));
      next ??= _firstOrNull(loaded);
      _selectedNode = next;
    } on ApiException catch (error) {
      _error = error.message;
    } finally {
      _loadingNodes = false;
      _safeNotify();
    }
  }

  void selectNode(VpnNodeInfo node) {
    if (_state != VpnUiState.disconnected) {
      _notice = 'Disconnect first to switch server.';
      _safeNotify();
      return;
    }
    _selectedNode = node;
    _error = null;
    _safeNotify();
  }

  static VpnNodeInfo? _firstOrNull(Iterable<VpnNodeInfo> items) {
    for (final VpnNodeInfo item in items) return item;
    return null;
  }

  // --- connect / disconnect ------------------------------------------------

  Future<void> connect() async {
    if (_busy || _state == VpnUiState.connecting || _state == VpnUiState.connected) {
      return;
    }

    final VpnNodeInfo? node = _selectedNode;
    if (node == null) {
      _error = 'No VPN node is available yet.';
      _safeNotify();
      return;
    }
    if (!node.connectable) {
      _error = '${node.name} is ${node.status.toLowerCase()} right now.';
      _safeNotify();
      return;
    }

    _busy = true;
    _error = null;
    _notice = null;
    _exitIp = null;
    _pingSample = const PingSample.empty();
    _state = VpnUiState.connecting;
    _safeNotify();

    try {
      // 1. Our public key must be registered and the tokens device-scoped.
      await _auth.ensureDeviceRegistered();

      // 2. The control plane allocates an IP and tells the node to add the peer.
      final ConnectResult result = await _api.connect(nodeId: node.id);
      _session = result.session;
      _tunnel = result.tunnel;
      _peerReady = result.session.isActive;

      if (result.tunnel.peerPublicKey.isEmpty || result.tunnel.endpoint.isEmpty) {
        throw StateError('the node returned an incomplete tunnel configuration');
      }

      // 3. The private key is read from secure storage at the last moment.
      final String? privateKey = await _auth.readTunnelPrivateKey();
      if (privateKey == null) {
        throw StateError('this device has no WireGuard key');
      }

      // 4. Raise the tunnel. On first use Android shows the system VPN dialog.
      await _vpn.start(tunnel: result.tunnel, privateKeyBase64: privateKey);

      _connectedSince = DateTime.now();
      _startTimers();
      _armConnectWatchdog();
    } on ApiException catch (error) {
      _error = error.message;
      await _rollbackConnect();
    } catch (error) {
      _error = 'Could not start the tunnel: $error';
      await _rollbackConnect();
    } finally {
      _busy = false;
      _safeNotify();
    }
  }

  Future<void> disconnect() async {
    if (_state == VpnUiState.disconnecting) return;

    _state = VpnUiState.disconnecting;
    _busy = true;
    _safeNotify();

    try {
      // Local teardown first, so user traffic stops immediately even if the
      // control plane is slow or unreachable.
      await _vpn.stop();
      // Then release the session: the control plane instructs the node to remove
      // the peer and frees the assigned IP.
      await _closeServerSession(reason: 'user request');
    } finally {
      _resetConnectionState();
      _state = VpnUiState.disconnected;
      _busy = false;
      _safeNotify();
    }
  }

  Future<void> _rollbackConnect() async {
    await _vpn.stop();
    await _closeServerSession(reason: 'connect failed');
    _resetConnectionState();
    _state = VpnUiState.disconnected;
  }

  Future<void> _closeServerSession({required String reason}) async {
    final String? sessionId = _session?.id;
    if (sessionId == null) return;
    debugPrint('vpn: closing session $sessionId ($reason)');
    try {
      await _api.disconnect(sessionId: sessionId);
    } on ApiException catch (error) {
      // Already closed server-side, or the network is down; nothing else to do.
      debugPrint('vpn: disconnect call failed: ${error.message}');
    }
  }

  // --- status polling ------------------------------------------------------

  Future<void> refreshStatus() => _syncWithServer();

  Future<void> _syncWithServer({bool initial = false}) async {
    try {
      final VpnStatusInfo status = await _api.status();
      final TunnelStage stage = await _vpn.currentStage();
      _peerReady = status.peerReady;
      if (status.session != null) _session = status.session;

      if (status.connected && stage.isConnected) {
        _state = VpnUiState.connected;
        _connectedSince ??= status.session?.connectedAt ?? DateTime.now();
        _startTimers();
      } else if (status.connected && !stage.isConnected && initial) {
        // The server has a live session but no tunnel is running here: the app
        // was killed or the phone rebooted. Close it so the node drops the peer
        // instead of keeping it installed forever.
        _notice = 'A previous session was still open and has been closed.';
        await _closeServerSession(reason: 'stale session');
        _resetConnectionState();
        _state = VpnUiState.disconnected;
      } else if (!status.connected && stage.isConnected) {
        // A tunnel with no session cannot route anything: tear it down.
        _notice = 'The tunnel was closed because the session is no longer valid.';
        await _vpn.stop();
        _resetConnectionState();
        _state = VpnUiState.disconnected;
      } else if (!status.connected && _state == VpnUiState.connected) {
        _notice = 'The session was closed by the server.';
        _resetConnectionState();
        _state = VpnUiState.disconnected;
      }

      // Subscription expiry / user disable must also end an active tunnel.
      if (!status.subscriptionActive && _state == VpnUiState.connected) {
        _notice = 'Subscription is not active any more. Disconnecting.';
        await disconnect();
        return;
      }

      _updateDuration();
    } on ApiException catch (error) {
      // Do not tear down the tunnel just because the control plane blipped.
      debugPrint('vpn: status refresh failed: ${error.message}');
    }
    _safeNotify();
  }

  // --- timers --------------------------------------------------------------

  void _startTimers() {
    _statusTimer ??= Timer.periodic(
      AppConfig.statusPollInterval,
      (_) => refreshStatus(),
    );
    _pingTimer ??= Timer.periodic(AppConfig.pingInterval, (_) => _samplePing());
    _tickTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _updateDuration();
      _safeNotify();
    });
  }

  void _stopTimers() {
    _statusTimer?.cancel();
    _statusTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    _watchdog?.cancel();
    _watchdog = null;
  }

  /// If the platform never reports a connected stage, the UI must not sit in
  /// "Connecting" forever: surface the failure and clean up.
  void _armConnectWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 20), () async {
      if (_state != VpnUiState.connecting) return;
      final TunnelStage stage = await _vpn.currentStage();
      if (stage.isConnected) {
        _onStage(TunnelStage.connected);
        return;
      }
      final String endpoint = _tunnel?.endpoint ?? 'the node';
      _error = 'The tunnel did not come up within 20 seconds. '
          'Check that UDP traffic to $endpoint is allowed.';
      await _rollbackConnect();
      _safeNotify();
    });
  }

  Future<void> _samplePing() async {
    if (_state != VpnUiState.connected) return;
    final PingSample sample = await _pingService.measure(gatewayIp: _tunnel?.gatewayIp);
    _pingSample = sample;
    _safeNotify();
  }

  Future<void> _probeExitIp() async {
    final String? ip = await _api.probeExitIp();
    if (ip == null) return;
    _exitIp = ip;
    _safeNotify();
  }

  void _updateDuration() {
    if (_state != VpnUiState.connected) {
      _connectedFor = Duration.zero;
      return;
    }
    final DateTime? since = _session?.connectedAt ?? _connectedSince;
    if (since != null) _connectedFor = DateTime.now().difference(since);
  }

  void _resetConnectionState() {
    _stopTimers();
    _session = null;
    _tunnel = null;
    _exitIp = null;
    _peerReady = false;
    _pingSample = const PingSample.empty();
    _connectedSince = null;
    _connectedFor = Duration.zero;
  }

  // --- platform stage events ----------------------------------------------

  void _onStage(TunnelStage stage) {
    _tunnelStage = stage;
    switch (stage) {
      case TunnelStage.connected:
        _watchdog?.cancel();
        _watchdog = null;
        _state = VpnUiState.connected;
        _connectedSince ??= DateTime.now();
        _startTimers();
        _probeExitIp();
        refreshStatus();
        break;
      case TunnelStage.denied:
        // The user declined Android's VPN permission dialog.
        _error = 'Android VPN permission was denied. Tap CONNECT and allow it.';
        _rollbackConnect().ignore();
        break;
      case TunnelStage.disconnected:
        if (_state == VpnUiState.connected) {
          _notice = 'The tunnel was closed.';
          _closeServerSession(reason: 'tunnel dropped').ignore();
          _resetConnectionState();
          _state = VpnUiState.disconnected;
        }
        break;
      case TunnelStage.connecting:
      case TunnelStage.preparing:
        if (_state == VpnUiState.disconnected) _state = VpnUiState.connecting;
        break;
      case TunnelStage.disconnecting:
        _state = VpnUiState.disconnecting;
        break;
      case TunnelStage.error:
        _error = 'The VPN engine reported an error.';
        break;
      case TunnelStage.unknown:
        break;
    }
    _safeNotify();
  }
}
