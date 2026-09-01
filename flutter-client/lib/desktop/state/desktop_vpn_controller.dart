import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../config.dart';
import '../../models/models.dart';
import '../../platform/tunnel_backend.dart';
import '../../services/api_client.dart';
import '../../services/ping_service.dart';
import '../../state/auth_controller.dart';
import '../logic/connection_phase.dart';
import '../logic/node_selector.dart';
import '../services/app_paths.dart';
import '../services/desktop_log.dart';
import '../services/service_bootstrap.dart';
import 'desktop_settings.dart';
import 'usage_store.dart';

/// Orchestrates the whole desktop connect lifecycle.
///
/// Design rules baked in here:
///  * The Windows tunnel is the source of truth. The UI mirrors it; it never
///    invents a state the tunnel does not have.
///  * CONNECTED is only published after [TunnelVerifier] agrees.
///  * The control API going away never tears down a healthy tunnel.
///  * Closing the window does not touch this controller at all.
///
/// Hard lessons from the first Windows build, all fixed below:
///  * Loading the server list must never sit behind the tunnel service probe.
///    It used to be chained after it, so a slow or missing service left the
///    app with an empty server list and no explanation.
///  * No failure may be swallowed. `refreshNodes` used to end in
///    `catch (_) {}`, which is why "no servers" looked like "no servers exist".
///    Every failure now lands in [nodesError], the log, and the home banner.
///  * Auto selection must degrade instead of returning nothing, otherwise the
///    server row shows a placeholder twice and Connect has no target.
///  * Elevation prompts only ever happen for an explicit user action.
class DesktopVpnController extends ChangeNotifier {
  DesktopVpnController({
    required ApiClient api,
    required AuthController auth,
    required TunnelBackend tunnel,
    required SettingsStore settings,
    required UsageStore usage,
    PingService? ping,
    TunnelVerifier? verifier,
    ServiceBootstrap? service,
  })  : _api = api,
        _auth = auth,
        _tunnel = tunnel,
        _settings = settings,
        _usage = usage,
        _ping = ping ?? PingService(),
        _service = service,
        _verifier = verifier ??
            TunnelVerifier(handshakeStaleAfter: AppConfig.handshakeStaleAfter);

  final ApiClient _api;
  final AuthController _auth;
  final TunnelBackend _tunnel;
  final SettingsStore _settings;
  final UsageStore _usage;
  final PingService _ping;
  final TunnelVerifier _verifier;

  /// Optional: only present on Windows builds that can talk to the SCM.
  final ServiceBootstrap? _service;

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

  // ---- diagnostics ----
  String? _serviceProblem;
  String? _nodesError;
  String? _autoFallbackReason;
  bool _nodesLoading = false;
  bool _serviceRepairing = false;
  int _nodeRetries = 0;
  Timer? _nodeRetryTimer;
  bool _bootstrapping = false;

  // ---- internals ----
  Timer? _statusTimer;
  Timer? _serverTimer;
  Timer? _pingTimer;
  Timer? _connectDeadline;
  bool _busy = false;
  bool _disposed = false;
  int _baselineRx = 0;
  bool _dataObserved = false;
  /// Reconnect ladder. 0 means "not reconnecting"; every failed attempt raises
  /// it and the wait doubles - 1s, 2s, 4s, 8s, 16s, 30s. A backend that is
  /// being redeployed is back within one or two steps, and the user never has
  /// to press anything.
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  String? _activeSessionId;
  List<String> _activeEndpointIps = const <String>[];
  ServerTunnelStatus? _lastServerStatus;
  int _serverStatusFailures = 0;

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

  /// Why the privileged tunnel service cannot be used, or null when it can.
  String? get serviceProblem => _serviceProblem;

  /// Why the server list is empty, or null when it loaded.
  String? get nodesError => _nodesError;

  bool get nodesLoading => _nodesLoading;
  bool get serviceRepairing => _serviceRepairing;

  /// Set when Auto had to fall back to a less-than-ideal node.
  String? get autoFallbackReason => _autoFallbackReason;

  /// True on plans that may not choose a server by hand (requirement 8).
  bool get manualSelectionLocked => !manualSelectionAllowed(_auth.subscription);

  /// The list the user actually works with.
  ///
  /// Internal nodes are stripped for production builds, with one hard rule:
  /// filtering must never leave the account with zero servers. The real case
  /// that broke the first release was a fleet of exactly one node whose handle
  /// matched an internal marker: the list came back empty, Auto reported
  /// no_available_nodes and Connect could not do anything. The node is now kept
  /// and only its *label* is sanitised - see publicNodeTitle.
  List<VpnNodeInfo> get userVisibleNodes =>
      selectableNodes(_nodes, internalBuild: AppConfig.internalBuild);

  /// True when every node in the fleet would normally be hidden.
  bool get fleetLooksInternal =>
      fleetIsInternalOnly(_nodes, internalBuild: AppConfig.internalBuild);

  /// Exposed for account panels that need to list or revoke devices.
  ApiClient get api => _api;

  /// Language for user-facing text produced here. Set by the shell, because
  /// these strings end up in banners the user reads.
  bool _ru = false;
  set russian(bool value) => _ru = value;

  bool get autoSelectionEnabled => _settings.value.autoNodeSelection;

  Duration? get connectedFor {
    final DateTime? since = _connectedSince;
    if (since == null) return null;
    return DateTime.now().difference(since);
  }

  /// Clipboard-ready state dump plus the rolling log. This is what the user
  /// sends when something still does not work.
  String diagnosticsDump() {
    final StringBuffer sb = StringBuffer();
    sb.writeln('GlukVPN desktop diagnostics');
    sb.writeln('time      : ${DateTime.now().toIso8601String()}');
    sb.writeln('api       : ${AppConfig.activeBaseUrl}');
    sb.writeln('internal  : ${AppConfig.internalBuild}');
    sb.writeln('auth      : ${_auth.stage}');
    sb.writeln('user      : ${_auth.user?.publicId ?? '-'}');
    sb.writeln('subscript.: ${_auth.subscription?.status ?? '-'}');
    sb.writeln('service   : ready=$_serviceReady');
    sb.writeln('service ? : ${_serviceProblem ?? '-'}');
    sb.writeln('phase     : $_phase ($_statusDetail)');
    sb.writeln('message   : ${_userMessage ?? '-'}');
    sb.writeln(
      'nodes     : total=${_nodes.length} visible=${userVisibleNodes.length}',
    );
    sb.writeln('nodes ?   : ${_nodesError ?? '-'}');
    sb.writeln('selected  : ${_selectedNode?.id ?? '-'}');
    sb.writeln('auto      : ${_settings.value.autoNodeSelection}');
    sb.writeln('auto why  : ${_autoSelection?.reason ?? _autoFallbackReason ?? '-'}');
    sb.writeln('tunnel    : ${_snapshot.state}');
    sb.writeln('vpn ip    : ${_snapshot.vpnIp ?? '-'}');
    sb.writeln('rx/tx     : ${_snapshot.rxBytes}/${_snapshot.txBytes}');
    sb.writeln('--- log ---');
    sb.writeln(dlog.dump());
    sb.writeln('--- service log (tail) ---');
    sb.writeln(_serviceLogTail());
    return sb.toString();
  }

  /// Last lines the privileged service wrote.
  ///
  /// tunnel_error is produced inside GlukVpnTunnelService, so the UI log on its
  /// own could never explain it: the dump stopped right after "tunnel up
  /// accepted". Whatever the service logged now travels with the diagnostics.
  String _serviceLogTail({int lines = 40}) {
    try {
      final File file = File(AppPaths().serviceLogPath);
      if (!file.existsSync()) return '(no service log at ${file.path})';
      final List<String> all = file.readAsLinesSync();
      final int from = all.length > lines ? all.length - lines : 0;
      return all.sublist(from).join('\n');
    } catch (e) {
      return '(service log unreadable: $e)';
    }
  }

  // -------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------

  /// Called at startup and again whenever the account becomes authenticated.
  ///
  /// Every step is fault-isolated: one failing step can no longer prevent the
  /// others from running.
  Future<void> bootstrap() async {
    if (_disposed || _bootstrapping) return;
    _bootstrapping = true;
    dlog.write('vpn', 'bootstrap start (auth=${_auth.stage})');

    try {
      // Deliberately concurrent. The node list comes from the control API and
      // has nothing to do with the local tunnel service, so it must not wait
      // for a pipe probe that can take seconds or fail outright.
      await Future.wait<void>(<Future<void>>[
        _guard('nodes', refreshNodes),
        _guard('service', () async {
          await _probeService();
          await adopt();
        }),
      ]);

      _startStatusPolling();
      unawaited(_guard('exit-ip', _refreshPublicIp));

      if (_settings.value.autoConnect &&
          _phase == ConnectionPhase.disconnected &&
          _auth.stage == AuthStage.authenticated) {
        dlog.write('vpn', 'auto-connect enabled, connecting');
        unawaited(connect());
      }
    } finally {
      _bootstrapping = false;
      dlog.write(
        'vpn',
        'bootstrap done: serviceReady=$_serviceReady '
            'nodes=${_nodes.length} visible=${userVisibleNodes.length}',
      );
      _notify();
    }
  }

  /// Runs [body], turning any throw into a logged, non-fatal event.
  Future<void> _guard(String tag, Future<void> Function() body) async {
    try {
      await body();
    } catch (e) {
      dlog.error('vpn/$tag', 'step failed', e);
    }
  }

  /// Reads live state from the service and republishes it without changing
  /// anything. This is what makes reopening the window instant and correct.
  Future<void> adopt() async {
    final TunnelSnapshot snap = await _tunnel.status();
    _snapshot = snap;
    _activeSessionId = snap.sessionId;

    if (snap.state == TunnelState.connected) {
      dlog.write('vpn', 'adopted a live tunnel (session=${snap.sessionId})');
      _baselineRx = snap.rxBytes;
      _dataObserved = snap.rxBytes > 0;
      final Duration? since = snap.uptime(DateTime.now().toUtc());
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
  // Tunnel service
  // -------------------------------------------------------------------

  /// Non-elevating probe. Never shows a UAC prompt.
  Future<void> _probeService() async {
    final ServiceBootstrap? svc = _service;

    if (svc != null) {
      try {
        final ServiceInstallState state = svc.queryState();
        dlog.write('service', 'SCM reports $state');
        _serviceProblem = state == ServiceInstallState.running
            ? null
            : ServiceBootstrap.describe(state);
      } catch (e) {
        dlog.error('service', 'SCM query failed', e);
        _serviceProblem = 'Could not query the Windows service manager: $e';
      }
    }

    try {
      _serviceReady = await _tunnel.isAvailable();
    } catch (e) {
      dlog.error('service', 'pipe probe threw', e);
      _serviceReady = false;
    }

    if (_serviceReady) {
      _serviceProblem = null;
    } else {
      _serviceProblem ??= 'The tunnel service is not answering on '
          '\\\\.\\pipe\\${AppConfig.tunnelPipeName}.';
    }

    dlog.write('service', 'ready=$_serviceReady problem=${_serviceProblem ?? '-'}');
    _notify();
  }

  /// Installs and/or starts the privileged service. This is the only path that
  /// may raise a UAC prompt, and it is always the result of the user pressing
  /// a button.
  Future<void> repairService() async {
    final ServiceBootstrap? svc = _service;
    if (svc == null) {
      _serviceProblem = 'Service control is not available in this build.';
      _notify();
      return;
    }
    if (_serviceRepairing) return;

    _serviceRepairing = true;
    _notify();
    dlog.write('service', 'repair requested by user');

    try {
      final ServiceInstallState state = await svc.ensureInstalledAndRunning();
      dlog.write('service', 'repair finished in state $state');
      _serviceProblem = state == ServiceInstallState.running
          ? null
          : ServiceBootstrap.describe(state);
      await _probeService();
    } catch (e) {
      dlog.error('service', 'repair failed', e);
      _serviceProblem = 'Could not start the tunnel service: $e';
    } finally {
      _serviceRepairing = false;
      _notify();
    }
  }

  // -------------------------------------------------------------------
  // Connect / disconnect
  // -------------------------------------------------------------------

  Future<void> connect({VpnNodeInfo? node, bool automatic = false}) async {
    if (_busy) return;
    _busy = true;
    // A connect the user asked for starts the ladder over. An automatic retry
    // must not, or the backoff would reset to one second on every attempt and
    // hammer a control plane that is still restarting.
    if (!automatic) _cancelReconnect();

    try {
      _setPhase(ConnectionPhase.connecting, detail: 'preparing');
      _userMessage = null;
      dlog.write('connect', 'requested (node=${node?.id ?? 'auto'})');

      if (_auth.stage != AuthStage.authenticated) {
        _fail(
          ConnectionPhase.sessionExpired,
          'not_authenticated',
          'Sign in again to connect.',
        );
        return;
      }

      // One repair attempt, because pressing Connect is an explicit action and
      // a UAC prompt here is understandable.
      if (!_serviceReady) {
        await _probeService();
        if (!_serviceReady) {
          await repairService();
        }
        if (!_serviceReady) {
          _fail(
            ConnectionPhase.connectionFailed,
            'tunnel_service_unavailable',
            _serviceProblem ??
                'The GlukVPN tunnel service is not running.',
          );
          return;
        }
      }

      // Make sure this machine is a registered device before asking for a
      // peer. Windows occupies exactly one device slot (requirement 17).
      try {
        await _auth.ensureDeviceRegistered();
      } catch (e) {
        dlog.error('connect', 'device registration failed', e);
        _fail(
          ConnectionPhase.limitReached,
          'device_registration_failed',
          'Could not register this PC as a device: $e',
        );
        return;
      }

      final VpnNodeInfo? target = node ?? await _resolveTargetNode();
      if (target == null) {
        _fail(
          ConnectionPhase.serverUnavailable,
          'no_available_nodes',
          _nodesError ??
              (_ru
                  ? 'Сейчас нет доступных серверов. Обновите список.'
                  : 'No servers are available right now.'),
        );
        return;
      }
      _selectedNode = target;
      dlog.write('connect', 'target node ${target.id}');

      ConnectResult result;
      try {
        result = await _api.connect(nodeId: target.id);
      } on ApiException catch (e) {
        dlog.error(
          'connect',
          'POST /api/vpn/connect failed',
          '${e.statusCode} ${e.code} ${e.message}',
        );
        _fail(
          phaseForApiError(
            statusCode: e.statusCode,
            code: e.code,
            refreshFailed: e.isUnauthorized,
          ),
          e.code ?? 'api_error',
          _describeApi(e),
        );
        return;
      } catch (e) {
        dlog.error('connect', 'connect call threw', e);
        _fail(ConnectionPhase.connectionFailed, 'connect_failed', e.toString());
        return;
      }

      final String? privateKey = await _auth.readTunnelPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        dlog.error('connect', 'no tunnel private key on this device');
        _fail(
          ConnectionPhase.connectionFailed,
          'missing_private_key',
          'The tunnel key for this device is missing. Sign out and back in.',
        );
        return;
      }

      String conf =
          result.tunnel.toWgQuickConfig(privateKeyBase64: privateKey);
      _activeSessionId = result.session.id;

      // Resolve the node's hostname now, while ordinary DNS still works.
      //
      // The kill switch is a WFP filter that blocks everything except the
      // tunnel, port 53 included. If the config still carries a name by the
      // time that filter is armed, the worker has nothing left to resolve it
      // with and the connect dies as tunnel_error. Resolving here also hands
      // WFP a literal address to permit, which it needs either way.
      final ({String host, String ip}) endpoint =
          await _resolveEndpoint(result.tunnel);
      if (endpoint.ip.isNotEmpty && endpoint.ip != endpoint.host) {
        conf = conf.replaceAll(endpoint.host, endpoint.ip);
        dlog.write('connect', 'endpoint resolved before the tunnel is armed');
      }
      _activeEndpointIps =
          endpoint.ip.isEmpty ? const <String>[] : <String>[endpoint.ip];

      final DesktopSettings settings = _settings.value;
      final TunnelUpOptions options = TunnelUpOptions(
        adapterName: AppConfig.desktopAdapterName,
        killSwitch: settings.killSwitch,
        dns: settings.dns.isNotEmpty ? settings.dns : result.tunnel.dns,
        mtu: settings.mtu,
        splitMode: settings.splitMode,
        splitApps: settings.splitApps,
        // "Always direct" from the browser extension: hosts and subnets that
        // must never travel through the tunnel.
        bypassRoutes: settings.bypassRoutes,
        endpointIps: _activeEndpointIps,
      );

      _setPhase(ConnectionPhase.connecting, detail: 'bringing_up');
      _armConnectDeadline();

      final TunnelResult up = await _tunnel.up(
        wgConf: conf,
        sessionId: result.session.id,
        options: options,
      );

      if (!up.ok) {
        dlog.error(
          'connect',
          'tunnel up rejected',
          '${up.errorCode} ${up.errorMessage}',
        );
        _fail(
          ConnectionPhase.connectionFailed,
          up.errorCode ?? 'tunnel_up_failed',
          up.errorMessage ?? 'The tunnel service refused to start the tunnel.',
        );
        // Release the server-side peer so we do not leak a session.
        unawaited(_releaseServerSession());
        return;
      }

      dlog.write('connect', 'tunnel up accepted, waiting for verification');
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
      dlog.write('disconnect', 'requested (user=$userInitiated)');
      _cancelConnectDeadline();
      _setPhase(ConnectionPhase.disconnecting, detail: 'tearing_down');

      final TunnelResult down = await _tunnel.down();
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
    if (enabled) _resolveSelection();
    _notify();
  }

  // -------------------------------------------------------------------
  // Polling and verification
  // -------------------------------------------------------------------

  Future<void> _pollTunnel() async {
    if (_disposed || _busy) return;

    try {
      _snapshot = await _tunnel.status();
    } catch (e) {
      dlog.error('poll', 'status failed', e);
      return;
    }

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
      final VpnStatusInfo status = await _api.status();
      _session = status.session;
      _lastServerStatus = ServerTunnelStatus(
        peerReady: status.peerReady,
        subscriptionActive: status.subscriptionActive,
      );
      _serverStatusFailures = 0;
    } on ApiException catch (e) {
      // Auth problems are real; transport problems are not the tunnel's fault.
      if (e.isUnauthorized || e.isForbidden) {
        final ConnectionPhase mapped =
            phaseForApiError(statusCode: e.statusCode, code: e.code);
        if (mapped.requiresReauth || mapped == ConnectionPhase.accessRevoked) {
          dlog.error(
            'status',
            'session/access rejected',
            '${e.statusCode} ${e.code}',
          );
          _fail(mapped, e.code ?? 'auth_error', _describeApi(e));
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

  Future<void> _reevaluate({required bool fetchServerStatus}) async {
    if (fetchServerStatus) {
      await refreshServerStatus();
      return;
    }

    final TunnelVerdict verdict = _verifier.evaluate(
      snapshot: _snapshot,
      serverStatus: _lastServerStatus,
      dataObserved: _dataObserved,
      now: DateTime.now().toUtc(),
    );

    // A dropped tunnel climbs the reconnect ladder instead of dumping an error
    // on the user. This is the ordinary case during a backend deploy: the node
    // is fine, the control plane is restarting, and by the second or third step
    // it answers again. The phase stays `connecting`, so the UI reads as
    // "reconnecting" instead of flashing a red failure that fixes itself.
    if (verdict.phase == ConnectionPhase.tunnelLost &&
        _reconnectAttempt < _maxReconnectAttempts) {
      _scheduleReconnect();
      return;
    }

    if (verdict.phase == ConnectionPhase.connected) {
      _cancelConnectDeadline();
      _cancelReconnect();
      _connectedSince ??= DateTime.now();
      unawaited(_refreshPublicIp());
    }

    _setPhase(verdict.phase, detail: verdict.reason);
  }

  /// Six steps cover about a minute of downtime, which is longer than a deploy
  /// takes. After that the tunnel really is lost and the user should be told.
  static const int _maxReconnectAttempts = 6;

  Duration _reconnectDelay(int attempt) {
    final int seconds = 1 << (attempt - 1);
    return Duration(seconds: seconds > 30 ? 30 : seconds);
  }

  void _scheduleReconnect() {
    if (_disposed || _reconnectTimer != null) return;
    _reconnectAttempt++;
    final Duration wait = _reconnectDelay(_reconnectAttempt);
    dlog.warn(
      'vpn',
      'tunnel lost, reconnect attempt $_reconnectAttempt in ${wait.inSeconds}s',
    );
    _setPhase(ConnectionPhase.connecting, detail: 'reconnecting');
    _reconnectTimer = Timer(wait, () {
      _reconnectTimer = null;
      unawaited(_autoReconnect());
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
  }

  Future<void> _autoReconnect() async {
    if (_disposed) return;
    // The user may have pressed Disconnect, or a hard failure may have taken
    // over, while we were waiting out the backoff. Reconnecting then would be
    // the app overriding an explicit decision.
    if (_phase != ConnectionPhase.connecting) {
      _cancelReconnect();
      return;
    }
    final VpnNodeInfo? node = _selectedNode;
    await _tunnel.down();
    // The service needs a moment to release the adapter before it is asked for
    // again under the same fixed GUID.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (_disposed) return;
    await connect(node: node, automatic: true);
  }

  void _armConnectDeadline() {
    _cancelConnectDeadline();
    _connectDeadline = Timer(AppConfig.connectTimeout, () {
      if (_phase == ConnectionPhase.connecting) {
        dlog.error('connect', 'timed out waiting for a verified tunnel');
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

  /// Public retry used by the home banner and the server screen.
  Future<void> retryNodes() {
    _nodeRetries = 0;
    return refreshNodes();
  }

  Future<void> refreshNodes() async {
    if (_disposed || _nodesLoading) return;

    if (_auth.stage != AuthStage.authenticated) {
      // Not an error the user can act on; it resolves as soon as the session
      // is restored, and the auth listener calls us again.
      dlog.write('nodes', 'skipped, auth stage is ${_auth.stage}');
      _scheduleNodeRetry();
      return;
    }

    _nodesLoading = true;
    _notify();

    try {
      final List<VpnNodeInfo> list = await _api.nodes();
      _nodes = list;
      _nodeRetries = 0;

      final int visible = userVisibleNodes.length;
      dlog.write('nodes', 'loaded ${list.length} nodes, $visible usable');

      if (list.isEmpty) {
        _nodesError = _ru
            ? 'Сервер вернул пустой список. Попробуйте обновить.'
            : 'The control plane returned an empty server list.';
      } else {
        // A fleet that looks internal is still perfectly usable: the nodes are
        // relabelled, not hidden. Refusing to connect over a naming convention
        // was the bug, not the safeguard.
        _nodesError = null;
        if (fleetLooksInternal) {
          dlog.warn(
            'nodes',
            'fleet of ${list.length} looks internal, kept usable with '
                'sanitised labels',
          );
        }
      }

      _resolveSelection();
      _notify();
      unawaited(_guard('pings', measureNodePings));
    } on ApiException catch (e) {
      _nodesError = _describeApi(e);
      dlog.error(
        'nodes',
        'GET /api/nodes failed',
        '${e.statusCode} ${e.code} ${e.message}',
      );
      _scheduleNodeRetry();
    } catch (e) {
      _nodesError = 'Could not reach ${AppConfig.activeBaseUrl}: $e';
      dlog.error('nodes', 'GET /api/nodes threw', e);
      _scheduleNodeRetry();
    } finally {
      _nodesLoading = false;
      _notify();
    }
  }

  /// Backoff retry. Without this, a single early 401 (session still being
  /// restored) left the app with an empty server list until restart.
  void _scheduleNodeRetry() {
    if (_disposed) return;
    _nodeRetryTimer?.cancel();

    const List<int> schedule = <int>[3, 8, 20, 45];
    final int seconds = _nodeRetries < schedule.length
        ? schedule[_nodeRetries]
        : schedule.last;
    _nodeRetries++;

    dlog.write('nodes', 'retry #$_nodeRetries in ${seconds}s');
    _nodeRetryTimer = Timer(Duration(seconds: seconds), () {
      if (_disposed) return;
      unawaited(refreshNodes());
    });
  }

  /// Chooses the node shown in the UI, honouring the remembered manual pick.
  void _resolveSelection() {
    final List<VpnNodeInfo> visible = userVisibleNodes;
    final String? remembered = _settings.value.lastNodeId;

    if (!_settings.value.autoNodeSelection && remembered != null) {
      final VpnNodeInfo? match =
          visible.where((VpnNodeInfo n) => n.id == remembered).firstOrNull;
      if (match != null) {
        _selectedNode = match;
        _autoFallbackReason = null;
        return;
      }
    }

    final VpnNodeInfo? auto = _autoTarget();
    if (auto != null) _selectedNode = auto;
  }

  /// Auto pick with a graded fallback.
  ///
  /// [pickBestNode] only returns nodes that are both online and connectable.
  /// When the fleet is small or a heartbeat is stale that yields nothing, which
  /// is why the server row used to show the placeholder twice and Connect had
  /// no target. Now we degrade: best -> any online -> any visible, and record
  /// the reason so it can be shown and logged.
  VpnNodeInfo? _autoTarget() {
    final AutoNodeChoice best = pickBestNode(
      _nodes,
      pings: _pings,
      // When the entire fleet looks internal it is scored normally instead of
      // being discarded, otherwise Auto would report no_available_nodes for a
      // perfectly working server. The label is sanitised separately.
      internalBuild: AppConfig.internalBuild || fleetLooksInternal,
      preferCountryCode: _auth.user?.originCountryCode,
    );
    _autoSelection = best;

    if (best.node != null) {
      _autoFallbackReason = null;
      return best.node;
    }

    final List<VpnNodeInfo> visible = userVisibleNodes;

    final List<VpnNodeInfo> online =
        visible.where((VpnNodeInfo n) => n.online).toList();
    if (online.isNotEmpty) {
      _autoFallbackReason = 'fallback_online_not_connectable';
      dlog.warn('nodes', 'auto fallback: ${_autoFallbackReason}');
      return online.first;
    }

    if (visible.isNotEmpty) {
      _autoFallbackReason = 'fallback_offline_node';
      dlog.warn('nodes', 'auto fallback: ${_autoFallbackReason}');
      return visible.first;
    }

    _autoFallbackReason = 'no_visible_nodes';
    return null;
  }

  /// Measures latency to visible nodes so Auto has real data to work with.
  Future<void> measureNodePings() async {
    final List<VpnNodeInfo> targets = userVisibleNodes
        .where((VpnNodeInfo n) => n.online && n.latencyHost != null)
        .take(12)
        .toList();

    for (final VpnNodeInfo node in targets) {
      if (_disposed) return;
      final String? host = node.latencyHost;
      if (host == null) continue;
      final PingSample? ms = await _ping.probeHost(host);
      if (ms != null && ms.ok) _pings[node.id] = ms.milliseconds!;
    }

    if (_settings.value.autoNodeSelection) _resolveSelection();
    _notify();
  }

  Future<void> _measureLivePing() async {
    final String? gateway = _snapshot.vpnIp;
    final PingSample sample = await _ping.measure(
      gatewayIp: gateway,
      apiBaseUrl: AppConfig.activeBaseUrl,
    );
    _currentPingMs = sample.milliseconds;
    _pingSource = sample.source;
    // Reaching the gateway is independent proof the tunnel carries traffic.
    if (sample.source == PingSource.tunnelGateway &&
        sample.milliseconds != null) {
      _dataObserved = true;
    }
    _notify();
  }

  Future<void> _refreshPublicIp() async {
    try {
      _publicIp = await _api.probeExitIp();
    } catch (e) {
      dlog.warn('exit-ip', 'probe failed: $e');
      _publicIp = null;
    }
    _notify();
  }

  Future<VpnNodeInfo?> _resolveTargetNode() async {
    if (_nodes.isEmpty) await refreshNodes();

    final DesktopSettings settings = _settings.value;
    final bool paid = manualSelectionAllowed(_auth.subscription);

    // Free accounts always get Auto (requirement 8).
    if (!paid || settings.autoNodeSelection) return _autoTarget();

    final String? remembered = settings.lastNodeId;
    if (remembered != null) {
      final VpnNodeInfo? match = userVisibleNodes
          .where((VpnNodeInfo n) => n.id == remembered)
          .firstOrNull;
      if (match != null && match.online && match.connectable) return match;
    }

    return _autoTarget();
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
    final DesktopSettings settings = _settings.value;

    if (!_phase.isConnected) return null;

    final TunnelResult result = await _tunnel.setSplit(
      mode: settings.splitMode,
      apps: settings.splitApps,
    );

    if (result.ok) return null;

    if (result.errorCode == 'reconnect_required') return 'reconnect_required';
    return result.errorMessage ?? result.errorCode;
  }

  // -------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------

  /// Turns an [ApiException] into something a human can act on.
  String _describeApi(ApiException e) {
    final String base = e.message.isEmpty ? 'Request failed' : e.message;
    if (e.isNetwork) {
      return '$base (cannot reach ${AppConfig.activeBaseUrl})';
    }
    final String code = e.code ?? '';
    final String status = e.statusCode == null ? '' : 'HTTP ${e.statusCode}';
    final String suffix = <String>[status, code]
        .where((String p) => p.isNotEmpty)
        .join(' \u00b7 ');
    return suffix.isEmpty ? base : '$base ($suffix)';
  }

  Future<void> _releaseServerSession() async {
    final String? id = _activeSessionId;
    if (id == null) return;
    _activeSessionId = null;
    try {
      await _api.disconnect(sessionId: id);
    } catch (_) {
      // The server reaps stale sessions on its own; nothing to do here.
    }
  }

  /// The endpoint host together with a literal address for it.
  ///
  /// Both are returned because both are needed: the address goes into the
  /// WireGuard config and into the WFP allow-list, while the original host is
  /// the text that has to be substituted inside the generated config.
  ///
  /// A failed lookup is deliberately not fatal. With the kill switch off the
  /// worker can still resolve the name itself, and refusing to connect here
  /// would break a case that works today.
  Future<({String host, String ip})> _resolveEndpoint(
    TunnelConfig config,
  ) async {
    final List<String> hosts = _endpointHostsOf(config);
    if (hosts.isEmpty) return (host: '', ip: '');
    final String host = hosts.first;

    // Already literal: nothing to look up, nothing to replace.
    if (InternetAddress.tryParse(host) != null) {
      return (host: host, ip: host);
    }

    try {
      final List<InternetAddress> found = await InternetAddress.lookup(
        host,
        type: InternetAddressType.IPv4,
      ).timeout(const Duration(seconds: 5));
      if (found.isNotEmpty) {
        return (host: host, ip: found.first.address);
      }
    } catch (e) {
      dlog.error('connect', 'endpoint lookup failed', e);
    }
    return (host: host, ip: host);
  }

  /// Extracts the endpoint host so the kill switch can whitelist it.
  List<String> _endpointHostsOf(TunnelConfig config) {
    final String endpoint = config.endpoint;
    if (endpoint.isEmpty) return const <String>[];
    final int colon = endpoint.lastIndexOf(':');
    final String host =
        colon > 0 ? endpoint.substring(0, colon) : endpoint;
    return <String>[host];
  }

  void _setPhase(ConnectionPhase next, {String detail = ''}) {
    if (_phase == next && _statusDetail == detail) return;
    if (_phase != next) {
      dlog.write('phase', '$_phase -> $next ($detail)');
    }
    _phase = next;
    _statusDetail = detail;
    _notify();
  }

  void _fail(ConnectionPhase phase, String detail, String? message) {
    _cancelConnectDeadline();
    dlog.error('phase', 'failed -> $phase [$detail]', message);
    _phase = phase;
    _statusDetail = detail;
    _userMessage = _humanise(detail, message);
    _notify();

    // ROUND 5, the "now the whole PC has no internet" bug.
    //
    // Tunnel::Up() arms the WFP kill switch and only Tunnel::Down() disarmed
    // it. When the WireGuard worker died by itself (tunnel_error 1.7s after
    // "tunnel up accepted") nothing released the block-all filters, so every
    // app on the machine stayed firewalled until the service was stopped or
    // the PC rebooted. Any failed connect now tears the tunnel down
    // explicitly, which drops the filters and the split-tunnel routes.
    if (phase == ConnectionPhase.connectionFailed ||
        phase == ConnectionPhase.tunnelLost ||
        phase == ConnectionPhase.serverUnavailable ||
        phase == ConnectionPhase.sessionExpired ||
        phase == ConnectionPhase.accessRevoked) {
      unawaited(releaseNetworkLocks(reason: detail));
    }
  }

  /// Drops the kill-switch filters and the split-tunnel routes.
  ///
  /// Also exposed in Settings -> Diagnostics as "restore internet access",
  /// because a half-dead tunnel used to leave the machine offline with no way
  /// out except `net stop GlukVpnTunnel` from an admin prompt.
  Future<bool> releaseNetworkLocks({String reason = 'manual'}) async {
    dlog.write('tunnel', 'releasing network locks ($reason)');
    try {
      await _tunnel.down();
      return true;
    } catch (e) {
      dlog.error('tunnel', 'releasing network locks failed', e);
      return false;
    }
  }

  /// Rewrites native error codes into something the user can act on.
  ///
  /// The tunnel service answers in English with codes such as
  /// driver_unavailable, and those strings went straight into a Russian UI as
  /// "WireGuard driver files are missing. Reinstall GlukVPN." The message also
  /// blamed the user for a packaging bug: the installer simply never shipped
  /// tunnel.dll. Both the wording and the cause are fixed now.
  String? _humanise(String detail, String? message) {
    switch (detail) {
      case 'driver_unavailable':
        return _ru
            ? 'Не хватает драйвера WireGuard. Переустановите GlukVPN — установщик поставит его сам.'
            : 'The WireGuard driver files are missing. Reinstall GlukVPN.';
      case 'service_unavailable':
      case 'service_missing':
        return _ru
            ? 'Служба GlukVPN не запущена. Нажмите «Установить службу».'
            : 'The GlukVPN service is not running. Use "Install service".';
      case 'tunnel_start_failed':
        return _ru
            ? 'Туннель не поднялся: файлы WireGuard в сборке несовместимы. Переустановите GlukVPN последней версией.'
            : 'The tunnel did not start: the bundled WireGuard files are mismatched. Reinstall the latest GlukVPN.'; 
      case 'tunnel_error':
        return _ru
            ? 'Туннель завершился с ошибкой. Интернет восстановлен, попробуйте подключиться снова.'
            : 'The tunnel exited with an error. Internet access is restored — try connecting again.';
      case 'tunnel_lost':
        return _ru
            ? 'Соединение с сервером потеряно. Переподключаемся.'
            : 'The tunnel lost contact with the server. Reconnecting.';
      case 'tunnel_service_unavailable':
        return _ru
            ? 'Служба туннеля не отвечает. Нажмите «Восстановить службу» в настройках.'
            : 'The tunnel service is not responding. Use "Repair service" in Settings.';
      case 'connect_timeout':
        return _ru
            ? 'Сервер не ответил вовремя. Проверьте сеть и попробуйте другой сервер.'
            : 'The server did not answer in time. Check your network or pick another server.';
      case 'not_authenticated':
        return _ru
            ? 'Сессия истекла. Войдите заново.'
            : 'Your session expired. Sign in again.';
    }
    return message;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Graceful shutdown from the tray Exit action.
  Future<void> shutdown({required bool disconnectTunnel}) async {
    dlog.write('vpn', 'shutdown (disconnect=$disconnectTunnel)');
    _statusTimer?.cancel();
    _serverTimer?.cancel();
    _pingTimer?.cancel();
    _nodeRetryTimer?.cancel();
    _cancelConnectDeadline();

    if (disconnectTunnel && _phase.isConnected) {
      await _tunnel.down();
      await _releaseServerSession();
    }

    // ROUND 5: "why is GlukVpnTunnelService always sitting in the background?"
    //
    // It was registered SERVICE_AUTO_START, so it booted with Windows and kept
    // running with the app closed. It is demand-start now, and when we leave
    // without an active tunnel we also stop it, so nothing of ours runs while
    // GlukVPN is not running.
    if (disconnectTunnel) {
      await releaseNetworkLocks(reason: 'shutdown');
      try {
        _service?.stopService();
        dlog.write('service', 'stop requested on exit');
      } catch (e) {
        dlog.error('service', 'stop on exit failed', e);
      }
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
    _nodeRetryTimer?.cancel();
    _cancelConnectDeadline();
    super.dispose();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final Iterator<T> it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
