import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../desktop/logic/node_selector.dart';
import '../models/models.dart';
import '../models/account_insights.dart';
import '../services/api_client.dart';
import '../services/ping_service.dart';
import '../services/tunnel_notification.dart';
import '../services/vpn_service.dart';
import '../utils/geo_dictionary.dart';
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
    TunnelNotifications? notifications,
  })  : _api = api,
        _vpn = vpn,
        _pingService = ping,
        _auth = auth,
        _notifications = notifications ?? TunnelNotifications();

  final ApiClient _api;
  final VpnService _vpn;
  final PingService _pingService;
  final AuthController _auth;

  /// The ongoing Android notification with the Disconnect button. Every call
  /// on it is a no-op off Android, so the controller stays host-agnostic.
  final TunnelNotifications _notifications;

  StreamSubscription<TunnelStage>? _stageSubscription;
  StreamSubscription<void>? _shadeSubscription;
  Timer? _statusTimer;
  Timer? _pingTimer;
  Timer? _tickTimer;
  Timer? _watchdog;
  Timer? _maintenanceRetry;
  bool _connectionIntent = false;
  bool _serviceMaintenance = false;

  List<VpnNodeInfo> _nodes = const <VpnNodeInfo>[];
  VpnNodeInfo? _selectedNode;
  VpnUiState _state = VpnUiState.disconnected;
  TunnelStage _tunnelStage = TunnelStage.unknown;
  VpnSessionInfo? _session;
  TunnelConfig? _tunnel;
  String? _exitIp;

  /// The address the world sees while *no* tunnel is up: the phone's own
  /// public IP. Probed after a disconnect settles and once at start-up, never
  /// carried over from a session.
  String? _homeIp;
  PingSample _pingSample = const PingSample.empty();
  String? _error;
  String? _notice;
  bool _loadingNodes = false;
  bool _busy = false;
  bool _peerReady = false;
  bool _disposed = false;
  bool _russian = false;

  /// True while the shade is showing our notification. Guards the redraw: the
  /// status poll runs every few seconds and starting a foreground service on
  /// each pass would be pure waste.
  bool _notificationShown = false;

  DateTime? _connectedSince;
  Duration _connectedFor = Duration.zero;

  ApiClient get api => _api;
  VpnService get vpnService => _vpn;
  List<VpnNodeInfo> get nodes => _nodes;
  VpnNodeInfo? get selectedNode => _selectedNode;
  VpnUiState get state => _state;
  TunnelStage get tunnelStage => _tunnelStage;
  VpnSessionInfo? get session => _session;
  TunnelConfig? get tunnel => _tunnel;

  /// Public address as probed *through* the tunnel. Null until the first probe
  /// after connecting answers, and cleared the moment the tunnel goes away.
  String? get exitIp => _exitIp;

  /// Public address without a tunnel, when known. See [_homeIp].
  String? get homeIp => _homeIp;

  /// What the "Public IP" cell should show for the current state: the exit IP
  /// while connected, the home IP while disconnected, nothing in between. The
  /// two are never mixed, so a stale exit address cannot be shown as the home
  /// address or the other way round.
  String? get publicIp {
    switch (_state) {
      case VpnUiState.connected:
        return _exitIp;
      case VpnUiState.disconnected:
        return _homeIp;
      case VpnUiState.connecting:
      case VpnUiState.disconnecting:
        return null;
    }
  }

  PingSample get ping => _pingSample;
  String? get error => _error;
  String? get notice => _notice;
  bool get loadingNodes => _loadingNodes;
  bool get busy => _busy;
  bool get peerReady => _peerReady;
  bool get serviceMaintenance => _serviceMaintenance;
  Duration get connectedFor => _connectedFor;

  /// Which language the notification in the shade is written in.
  ///
  /// Set from the interface language, exactly like the desktop controller does
  /// it: the shade is read by the user, not by a log.
  bool get russian => _russian;
  set russian(bool value) {
    if (_russian == value) return;
    _russian = value;
    // Switching the language must not leave yesterday's wording on screen.
    if (_notificationShown) _showTunnelNotification(force: true);
  }

  bool get isConnected => _state == VpnUiState.connected;
  bool get isTransitioning =>
      _state == VpnUiState.connecting || _state == VpnUiState.disconnecting;

  int get bytesRx => _session?.bytesRx ?? 0;
  int get bytesTx => _session?.bytesTx ?? 0;

  /// The address the control plane leased for this session.
  ///
  /// Null while disconnected, whatever the last status poll may have echoed
  /// back: a VPN IP belongs to a tunnel, and showing yesterday's lease next to
  /// an "inactive" badge reads as a leak.
  String? get assignedIp {
    if (_state == VpnUiState.disconnected) return null;
    return _session?.assignedVpnIp ?? _tunnel?.assignedIp;
  }

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
    _shadeSubscription ??= _notifications.disconnectRequests.listen(
      (void _) => _onShadeDisconnectRequest(),
    );
    try {
      await _vpn.initialize();
    } catch (error) {
      _error = 'The VPN engine could not be initialised: $error';
    }
    _notifications.requestNotificationPermission().ignore();
    await loadNodes();
    await _syncWithServer(initial: true);
    // A Disconnect pressed in the shade while the app was not running is
    // served here - before the first frame can claim the tunnel is still up.
    await syncShadeStop();
    if (_state == VpnUiState.disconnected) _probeHomeIp().ignore();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTimers();
    _maintenanceRetry?.cancel();
    _maintenanceRetry = null;
    _stageSubscription?.cancel();
    _stageSubscription = null;
    _shadeSubscription?.cancel();
    _shadeSubscription = null;
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

      // ROUND 25: the phone used to take the first connectable row the API
      // happened to return, so a busy node with 200 ms of ping could win over
      // an idle one. It now scores exactly like Windows and the browser
      // extension - latency, then current load, then spare capacity - through
      // the shared selector.
      final String? currentId = _selectedNode?.id;
      VpnNodeInfo? next;
      if (currentId != null) {
        next = _firstOrNull(
          loaded.where((VpnNodeInfo n) => n.id == currentId && n.connectable),
        );
      }
      next ??= pickBestNode(loaded).node;
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

  Future<void> connect({bool automatic = false}) async {
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

    if (!automatic) _connectionIntent = true;
    if (_serviceMaintenance) {
      _notice = _russian ? 'Сервис временно на техническом обслуживании.' : 'The service is temporarily under maintenance.';
      _scheduleMaintenanceRetry(30);
      _safeNotify();
      return;
    }
    _busy = true;
    _error = null;
    _notice = null;
    // A fresh session starts with nothing on the readouts: no exit address, no
    // lease and no latency from the previous one may survive into this one.
    _exitIp = null;
    _session = null;
    _tunnel = null;
    _pingSample = const PingSample.empty();
    _state = VpnUiState.connecting;
    _safeNotify();

    try {
      // On Android, request notification permission early so the shade notification appears.
      await _notifications.requestNotificationPermission();

      // Ensure Android system VPN permission dialog is accepted BEFORE allocating server session.
      final bool vpnPrepared = await _notifications.prepareVpn();
      if (!vpnPrepared) {
        _busy = false;
        _state = VpnUiState.disconnected;
        _error = _russian
            ? 'Для подключения необходимо разрешение на создание VPN.'
            : 'VPN permission is required to establish a connection.';
        _safeNotify();
        return;
      }

      await _vpn.syncPermissions();

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
      if (error.code == 'maintenance') {
        _serviceMaintenance = true;
        _notice = _russian ? 'Идут технические работы. Подключение возобновится автоматически.' : 'Maintenance is in progress. The connection will resume automatically.';
        _scheduleMaintenanceRetry(error.retryAfterSec ?? (error.details?['retryAfterSec'] as num?)?.toInt() ?? 30);
      } else {
        _error = error.message;
      }
      await _rollbackConnect();
    } catch (error) {
      _error = 'Could not start the tunnel: $error';
      await _rollbackConnect();
    } finally {
      _busy = false;
      _safeNotify();
    }
  }

  Future<void> disconnect({bool userInitiated = true}) async {
    if (_state == VpnUiState.disconnecting) return;
    if (userInitiated) {
      _connectionIntent = false;
      _maintenanceRetry?.cancel();
      _maintenanceRetry = null;
    }

    _state = VpnUiState.disconnecting;
    _busy = true;
    _safeNotify();

    try {
      // Сессия закрывается ДО обрыва туннеля. Раньше сначала шёл
      // _vpn.stop(): маршруты перестраивались, HTTP-запрос не доходил,
      // ошибка молча глоталась, и строка сессии навсегда оставалась
      // ACTIVE: устройство висело онлайн у всех на карте и в админке.
      // У расширения такой беды нет ровно потому, что оно не рвёт маршруты.
      await _closeServerSession(reason: 'user request');
      await _vpn.stop();
      // Если первая попытка не прошла (сеть уже разваливалась) —
      // добиваем уже по обычному каналу, без туннеля.
      await _closeServerSession(reason: 'user request retry');
    } finally {
      _resetConnectionState();
      _state = VpnUiState.disconnected;
      _busy = false;
      _safeNotify();
      _probeHomeIp(settle: const Duration(milliseconds: 1200)).ignore();
    }
  }

  Future<void> _rollbackConnect() async {
    await _vpn.stop();
    await _closeServerSession(reason: 'connect failed');
    _resetConnectionState();
    _state = VpnUiState.disconnected;
    _probeHomeIp(settle: const Duration(milliseconds: 1200)).ignore();
  }

  /// Паузы между попытками закрыть сессию.
  static const List<Duration> _closeBackoff = <Duration>[
    Duration.zero,
    Duration(milliseconds: 400),
    Duration(milliseconds: 1200),
  ];

  /// Сессия, закрытие которой сервер ещё не подтвердил. Пока она здесь,
  /// устройство числится онлайн, поэтому попытку надо досылать.
  String? _pendingClose;

  /// Досылает неподтверждённое отключение.
  Future<void> flushPendingClose() async {
    if (_pendingClose == null) return;
    await _closeServerSession(reason: 'pending close');
  }

  Future<void> _closeServerSession({required String reason}) async {
    final String? sessionId = _session?.id ?? _pendingClose;
    if (sessionId == null) return;
    _pendingClose = sessionId;
    debugPrint('vpn: closing session $sessionId ($reason)');
    for (final Duration wait in _closeBackoff) {
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      try {
        await _api.disconnect(sessionId: sessionId);
        _pendingClose = null;
        return;
      } on ApiException catch (error) {
        // 404 — сервер уже закрыл эту сессию, повторять нечего.
        if (error.statusCode == 404) {
          _pendingClose = null;
          return;
        }
        debugPrint('vpn: disconnect call failed: ${error.message}');
      } catch (error) {
        debugPrint('vpn: disconnect call failed: $error');
      }
    }
    // Последняя попытка — без sessionId: сервер сам найдёт живую сессию
    // этого устройства. Помогает, когда локальный id устарел.
    try {
      await _api.disconnect();
      _pendingClose = null;
    } catch (error) {
      debugPrint('vpn: session $sessionId left open: $error');
    }
  }

  // --- the Disconnect button in the notification shade ---------------------

  /// Draws the ongoing notification for a live tunnel.
  void _showTunnelNotification({bool force = false}) {
    if (_notificationShown && !force) return;
    _notificationShown = true;
    // ПУНКТ 14: в уведомлении должно быть название сервера
    // «Германия, Франкфурт», а не внутренний идентификатор узла
    // вида `de-prod-1`. Берём ту же локализацию, что и чип сервера
    // на главном экране, и никогда не показываем `node.name`.
    final VpnNodeInfo? node = _selectedNode;
    final String country = node == null
        ? ''
        : localizeCountry(node.countryCode,
            russian: _russian, fallback: node.country);
    final String city =
        node == null ? '' : localizeCity(node.city, russian: _russian);
    final String? place = country.isNotEmpty && city.isNotEmpty
        ? '$country, $city'
        : (country.isNotEmpty
            ? country
            : (city.isNotEmpty ? city : null));
    _notifications
        .show(
          title: _russian ? 'GlukVPN подключён' : 'GlukVPN is connected',
          body: place == null
              ? (_russian ? 'Туннель активен' : 'The tunnel is up')
              : (_russian ? 'Через $place' : 'Through $place'),
          actionLabel: _russian ? 'Отключить' : 'Disconnect',
          stoppingLabel: _russian ? 'Отключаем…' : 'Disconnecting…',
          channelName: _russian ? 'Состояние VPN' : 'VPN status',
        )
        .ignore();
  }

  /// The button was pressed while this isolate was alive.
  void _onShadeDisconnectRequest() {
    // The platform also recorded the request, in case the app died before it
    // could be served. It is being served right now, so clear that record -
    // otherwise the next tunnel the user raises would be torn down on resume.
    _notifications.consumeStopRequest().ignore();
    unawaited(_serveShadeStop());
  }

  /// Serves a Disconnect that was pressed while the app was not running.
  ///
  /// Called at start-up and on every resume. Reading the platform's record is
  /// what keeps the screen from coming back as "Connected" over a tunnel the
  /// user has already stopped from the shade.
  Future<void> syncShadeStop() async {
    if (!await _notifications.consumeStopRequest()) return;
    await _serveShadeStop();
  }

  /// The teardown itself: the tunnel first, then the session on the control
  /// plane (POST /api/vpn/disconnect through [_closeServerSession]).
  ///
  /// Deliberately not routed through [disconnect]: that one returns early when
  /// the app already believes it is disconnected, and the app's idea of the
  /// state is exactly what may be stale after a shade press.
  Future<void> _serveShadeStop() async {
    if (_state == VpnUiState.disconnecting) return;
    debugPrint('vpn: serving Disconnect from the notification shade');
    _state = VpnUiState.disconnecting;
    _busy = true;
    _safeNotify();
    try {
      await _vpn.stop();
      await _closeServerSession(reason: 'notification shade');
    } finally {
      _resetConnectionState();
      _state = VpnUiState.disconnected;
      _busy = false;
      _notice = _russian
          ? 'Отключено из шторки уведомлений.'
          : 'Disconnected from the notification shade.';
      _safeNotify();
      _probeHomeIp(settle: const Duration(milliseconds: 1200)).ignore();
    }
  }

  // --- status polling ------------------------------------------------------

  Future<void> refreshStatus() => _syncWithServer();

  Future<void> _syncWithServer({bool initial = false}) async {
    try {
      final VpnStatusInfo status = await _api.status();
      final TunnelStage stage = await _vpn.currentStage();
      _peerReady = status.peerReady;
      _serviceMaintenance = status.maintenance || status.nodeMaintenance;
      if (_serviceMaintenance && stage.isConnected) {
        _notice = _russian ? 'Сервис остановил туннель на время технических работ.' : 'The service stopped the tunnel for maintenance.';
        await _vpn.stop();
        _resetConnectionState();
        _state = VpnUiState.disconnected;
        _scheduleMaintenanceRetry(status.retryAfterSec);
        _safeNotify();
        return;
      }
      if (!_serviceMaintenance && _connectionIntent && _state == VpnUiState.disconnected && !initial) {
        unawaited(connect(automatic: true));
      }
      if (status.session != null) _session = status.session;

      if (status.connected && stage.isConnected) {
        _state = VpnUiState.connected;
        _connectedSince ??= status.session?.connectedAt ?? DateTime.now();
        _startTimers();
        // Also covers a tunnel adopted at start-up: whatever raised it, the
        // shade gets the control while it is up.
        _showTunnelNotification();
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
        _probeHomeIp(settle: const Duration(milliseconds: 1200)).ignore();
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

  void handleServiceStatus(ServiceStatus status) {
    final wasMaintenance = _serviceMaintenance;
    _serviceMaintenance = status.maintenance;
    if (status.maintenance) {
      if (_state == VpnUiState.connected) unawaited(disconnect(userInitiated: false));
      _scheduleMaintenanceRetry(status.retryAfterSec);
    } else if (wasMaintenance && _connectionIntent && _state == VpnUiState.disconnected) {
      _maintenanceRetry?.cancel();
      unawaited(connect(automatic: true));
    }
    _safeNotify();
  }

  void _scheduleMaintenanceRetry(int seconds) {
    _maintenanceRetry?.cancel();
    if (!_connectionIntent || _disposed) return;
    _maintenanceRetry = Timer(Duration(seconds: seconds.clamp(5, 300).toInt()), () async {
      if (!_connectionIntent || _disposed) return;
      try {
        final status = await _api.serviceStatus();
        handleServiceStatus(status);
        if (status.maintenance) _scheduleMaintenanceRetry(status.retryAfterSec);
      } catch (_) {
        _scheduleMaintenanceRetry(30);
      }
    });
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
    // The HTTPS fallback must hit the channel we are actually signed in to.
    final PingSample sample = await _pingService.measure(
      gatewayIp: _tunnel?.gatewayIp,
      apiBaseUrl: _api.baseUrl,
    );
    _pingSample = sample;
    _safeNotify();
  }

  /// Reads the address the world sees us as.
  ///
  /// [settle] exists because a probe fired the instant the tunnel reports up
  /// leaves before the platform has finished moving traffic onto it: the answer
  /// is then the home address, and the panel flashes it before correcting
  /// itself a moment later.
  Future<void> _probeExitIp({Duration settle = Duration.zero}) async {
    if (settle > Duration.zero) {
      await Future<void>.delayed(settle);
      if (_disposed || _state != VpnUiState.connected) return;
    }
    String? ip = await _api.probeExitIp();
    if (_disposed || _state != VpnUiState.connected) return;
    if (ip == null) {
      // Retry once after 2.5 seconds if network took a moment to settle
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      if (_disposed || _state != VpnUiState.connected) return;
      ip = await _api.probeExitIp();
    }
    if (_disposed || _state != VpnUiState.connected) return;
    _exitIp = ip ?? _selectedNode?.host;
    _safeNotify();
  }

  /// Reads the phone's own public address while no tunnel is up.
  ///
  /// [settle] gives the platform time to move traffic back off the tunnel after
  /// a disconnect; without it the first answer is still the node's address.
  /// The result is only kept if the app is *still* disconnected when it lands,
  /// so a connect started in the meantime never sees its home IP appear.
  Future<void> _probeHomeIp({Duration settle = Duration.zero}) async {
    if (settle > Duration.zero) {
      await Future<void>.delayed(settle);
    }
    if (_disposed || _state != VpnUiState.disconnected) return;
    final String? ip = await _api.probeExitIp();
    if (ip == null || _disposed || _state != VpnUiState.disconnected) return;
    if (ip == _homeIp) return;
    _homeIp = ip;
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
    // The tunnel is gone: the shade must stop offering to stop it.
    if (_notificationShown) {
      _notificationShown = false;
      _notifications.hide().ignore();
    }
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
        // The tunnel is up: put the Disconnect button in the shade, so the
        // user never has to open the app to stop it.
        _showTunnelNotification();
        // Settle window before the first exit-IP read: probing the instant the
        // platform reports the tunnel up answers over the old link and flashes
        // the home address in the panel.
        _probeExitIp(settle: const Duration(milliseconds: 1200)).ignore();
        refreshStatus();
        break;
      case TunnelStage.denied:
        // The user declined Android's VPN permission dialog.
        _error = 'Android VPN permission was denied. Tap CONNECT and allow it.';
        _rollbackConnect().ignore();
        break;
      case TunnelStage.disconnected:
        if (_state != VpnUiState.disconnected) {
          if (_state == VpnUiState.connected) {
            _notice = _russian ? 'Туннель был разорван.' : 'The tunnel was closed.';
            _closeServerSession(reason: 'tunnel dropped').ignore();
          }
          _resetConnectionState();
          _state = VpnUiState.disconnected;
          _safeNotify();
          _probeHomeIp(settle: const Duration(milliseconds: 1200)).ignore();
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
