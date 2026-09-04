import '../../widgets/connect_button.dart';
import '../../platform/tunnel_backend.dart';

/// Every user-visible state the desktop connect flow can be in.
///
/// Requirement 6 of the spec lists exactly these ten.
enum ConnectionPhase {
  disconnected,
  connecting,
  connected,
  disconnecting,
  serverUnavailable,
  connectionFailed,
  sessionExpired,
  limitReached,
  accessRevoked,
  tunnelLost,
}

extension ConnectionPhaseX on ConnectionPhase {
  bool get isBusy =>
      this == ConnectionPhase.connecting || this == ConnectionPhase.disconnecting;

  bool get isConnected => this == ConnectionPhase.connected;

  bool get isError {
    switch (this) {
      case ConnectionPhase.serverUnavailable:
      case ConnectionPhase.connectionFailed:
      case ConnectionPhase.sessionExpired:
      case ConnectionPhase.limitReached:
      case ConnectionPhase.accessRevoked:
      case ConnectionPhase.tunnelLost:
        return true;
      case ConnectionPhase.disconnected:
      case ConnectionPhase.connecting:
      case ConnectionPhase.connected:
      case ConnectionPhase.disconnecting:
        return false;
    }
  }

  /// The user must sign in again before anything else will work.
  bool get requiresReauth =>
      this == ConnectionPhase.sessionExpired ||
      this == ConnectionPhase.accessRevoked;

  /// Whether the big connect button should accept a tap.
  ///
  /// Note that recoverable failures stay enabled so the button doubles as
  /// "retry" — that is the behaviour users expect after a failed attempt.
  bool get connectEnabled {
    switch (this) {
      case ConnectionPhase.disconnected:
      case ConnectionPhase.connected:
      case ConnectionPhase.serverUnavailable:
      case ConnectionPhase.connectionFailed:
      case ConnectionPhase.tunnelLost:
      case ConnectionPhase.limitReached:
        return true;
      case ConnectionPhase.connecting:
      case ConnectionPhase.disconnecting:
      case ConnectionPhase.sessionExpired:
      case ConnectionPhase.accessRevoked:
        return false;
    }
  }

  /// Which tray .ico to show. Matches assets/tray/<name>.ico.
  String get trayIconName {
    switch (this) {
      case ConnectionPhase.connected:
        return 'on';
      case ConnectionPhase.connecting:
      case ConnectionPhase.disconnecting:
        return 'connecting';
      case ConnectionPhase.disconnected:
        return 'off';
      case ConnectionPhase.serverUnavailable:
      case ConnectionPhase.connectionFailed:
      case ConnectionPhase.sessionExpired:
      case ConnectionPhase.limitReached:
      case ConnectionPhase.accessRevoked:
      case ConnectionPhase.tunnelLost:
        return 'error';
    }
  }

  /// i18n key for the status line under the connect button.
  String get labelKey => 'phase.$name';

  ConnectPhase get buttonPhase {
    switch (this) {
      case ConnectionPhase.connected:
        return ConnectPhase.connected;
      case ConnectionPhase.connecting:
        return ConnectPhase.connecting;
      case ConnectionPhase.disconnecting:
        return ConnectPhase.disconnecting;
      case ConnectionPhase.disconnected:
      case ConnectionPhase.serverUnavailable:
      case ConnectionPhase.connectionFailed:
      case ConnectionPhase.sessionExpired:
      case ConnectionPhase.limitReached:
      case ConnectionPhase.accessRevoked:
      case ConnectionPhase.tunnelLost:
        return ConnectPhase.idle;
    }
  }
}

/// Which data plane the privileged service runs for a session.
///
/// ROUND 24 made sing-box the engine the service prefers; the WireGuard worker
/// stays as the fallback for nodes that advertise no TLS gateway. The UI has to
/// know which one is live, because "waiting for the WireGuard handshake" is a
/// lie on a sing-box tunnel - there is no handshake to wait for.
enum TunnelEngine {
  /// glukvpn-wg.exe: wireguard-go in userspace over Wintun.
  wireGuard,

  /// sing-box.exe: TUN inbound, VLESS over TLS outbound. The primary engine.
  singBox,
}

extension TunnelEngineX on TunnelEngine {
  /// What the Settings "Protocol" row shows.
  String get protocolLabel {
    switch (this) {
      case TunnelEngine.singBox:
        return 'VLESS over TLS \u00b7 sing-box (TUN)';
      case TunnelEngine.wireGuard:
        return 'WireGuard \u00b7 Wintun';
    }
  }

  /// The value the service reports in the `engine` status field.
  String get wireName =>
      this == TunnelEngine.singBox ? 'sing-box' : 'wireguard';
}

/// Parses the `engine` field of a service status reply. Null when the service
/// predates the field or has not decided yet (no tunnel requested).
TunnelEngine? tunnelEngineFromWire(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'sing-box':
    case 'singbox':
    case 'sing_box':
      return TunnelEngine.singBox;
    case 'wireguard':
    case 'wg':
      return TunnelEngine.wireGuard;
    default:
      return null;
  }
}

/// Implemented by backends that can say which engine they are running.
///
/// Kept apart from `TunnelBackend` so the platform-neutral interface in
/// `lib/platform/` does not have to grow a Windows-only notion.
abstract class TunnelEngineReporter {
  /// `sing-box` / `wireguard` as last reported by the service, or null when it
  /// has not said.
  String? get reportedEngine;
}

/// i18n key for a raw status detail code, or null when the code has no human
/// wording of its own (call sites then fall back to a generic phrase).
///
/// The codes come from [TunnelVerifier] and from `DesktopVpnController`; they
/// used to reach the home banner verbatim (`handshake_pending`), which is
/// neither readable nor true on a sing-box tunnel. Only the two handshake codes
/// are engine-specific: on WireGuard they *are* about the handshake, on
/// sing-box the same verdicts mean "the tunnel has not answered yet" and "the
/// tunnel went quiet".
String? statusDetailKey(String code, TunnelEngine engine) {
  final bool wg = engine == TunnelEngine.wireGuard;
  switch (code) {
    case 'preparing':
      return 'detail.preparing';
    case 'bringing_up':
      return 'detail.bringingUp';
    case 'handshake_pending':
      return wg ? 'detail.handshakePending.wg' : 'detail.waitingForTunnel';
    case 'handshake_stale':
      return wg ? 'detail.handshakeStale.wg' : 'detail.tunnelSilent';
    case 'peer_not_ready':
      return 'detail.peerNotReady';
    case 'no_traffic_yet':
      return 'detail.verifying';
    case 'verified':
      return 'detail.verified';
    case 'reconnecting':
      return 'detail.reconnecting';
    case 'tearing_down':
      return 'detail.tearingDown';
    case 'down':
      return 'detail.down';
    case 'tunnel_lost':
      return 'detail.tunnelLost';
    case 'tunnel_error':
      return 'detail.tunnelError';
    case 'tunnel_service_unavailable':
      return 'detail.serviceUnavailable';
    case 'tunnel_permission_denied':
      return 'detail.permissionDenied';
    case 'subscription_inactive':
      return 'detail.subscriptionInactive';
    case 'connect_timeout':
      return 'detail.connectTimeout';
    case 'not_authenticated':
      return 'detail.notAuthenticated';
    case 'no_available_nodes':
      return 'detail.noNodes';
    case 'device_limit_reached':
      return 'detail.deviceLimit';
    default:
      return null;
  }
}

/// Outcome of evaluating whether we may legitimately show CONNECTED.
class TunnelVerdict {
  const TunnelVerdict(this.phase, this.reason);

  final ConnectionPhase phase;

  /// Machine-readable reason, useful in logs and tests.
  final String reason;

  @override
  String toString() => 'TunnelVerdict(${phase.name}, $reason)';
}

/// Minimal view of `GET /api/vpn/status` needed by the verifier.
///
/// Declared here rather than importing the full model so this file stays
/// trivially testable and free of network types.
class ServerTunnelStatus {
  const ServerTunnelStatus({
    required this.peerReady,
    required this.subscriptionActive,
  });

  final bool peerReady;
  final bool subscriptionActive;
}

/// Decides when the UI is allowed to say CONNECTED.
///
/// This exists specifically to prevent the premature-CONNECTED bug the
/// Android client has. Four independent conditions must all hold:
///
///   1. the privileged service reports state == connected;
///   2. the liveness stamp is fresh (within [handshakeStaleAfter]) - the last
///      WireGuard handshake on that engine, the moment sing-box was last seen
///      alive on the other; the wire field is `lastHandshakeUnix` for both;
///   3. the control server agrees the peer is provisioned (peerReady);
///   4. we have observed actual data movement or a gateway ping.
///
/// Anything less is still "connecting". Critically, a *missing* server status
/// (API down, captive network) never invalidates an otherwise healthy tunnel —
/// the tunnel is the source of truth, not our control plane.
class TunnelVerifier {
  const TunnelVerifier({
    this.handshakeStaleAfter = const Duration(seconds: 180),
  });

  final Duration handshakeStaleAfter;

  TunnelVerdict evaluate({
    required TunnelSnapshot snapshot,
    ServerTunnelStatus? serverStatus,
    bool dataObserved = false,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now().toUtc();

    switch (snapshot.state) {
      case TunnelState.unavailable:
        return const TunnelVerdict(
          ConnectionPhase.connectionFailed,
          'tunnel_service_unavailable',
        );
      case TunnelState.denied:
        return const TunnelVerdict(
          ConnectionPhase.accessRevoked,
          'tunnel_permission_denied',
        );
      case TunnelState.error:
        return const TunnelVerdict(
          ConnectionPhase.connectionFailed,
          'tunnel_error',
        );
      case TunnelState.disconnecting:
        return const TunnelVerdict(
          ConnectionPhase.disconnecting,
          'tearing_down',
        );
      case TunnelState.disconnected:
        return const TunnelVerdict(ConnectionPhase.disconnected, 'down');
      case TunnelState.unknown:
      case TunnelState.connecting:
        return const TunnelVerdict(ConnectionPhase.connecting, 'bringing_up');
      case TunnelState.connected:
        break;
    }

    // Condition 3: subscription revoked out from under a live tunnel.
    if (serverStatus != null && !serverStatus.subscriptionActive) {
      return const TunnelVerdict(
        ConnectionPhase.limitReached,
        'subscription_inactive',
      );
    }

    // Condition 2: handshake freshness.
    final age = snapshot.handshakeAge(at);
    if (age == null) {
      return const TunnelVerdict(
        ConnectionPhase.connecting,
        'handshake_pending',
      );
    }
    if (age > handshakeStaleAfter) {
      // We had a handshake before and lost it: that is a dropped tunnel,
      // not a slow start.
      return const TunnelVerdict(
        ConnectionPhase.tunnelLost,
        'handshake_stale',
      );
    }

    // Condition 3 (positive form). A null serverStatus means the API is
    // unreachable; we deliberately do NOT punish the tunnel for that.
    if (serverStatus != null && !serverStatus.peerReady) {
      return const TunnelVerdict(
        ConnectionPhase.connecting,
        'peer_not_ready',
      );
    }

    // Condition 4: proof that packets actually flow.
    if (!dataObserved && snapshot.rxBytes <= 0) {
      return const TunnelVerdict(
        ConnectionPhase.connecting,
        'no_traffic_yet',
      );
    }

    return const TunnelVerdict(ConnectionPhase.connected, 'verified');
  }
}

/// Maps a control-API failure onto a user-facing phase.
///
/// [refreshFailed] distinguishes "token was stale but we recovered" from
/// "the session is genuinely gone".
ConnectionPhase phaseForApiError({
  int? statusCode,
  String? code,
  bool refreshFailed = false,
}) {
  final upper = code?.toUpperCase();

  if (statusCode == 401) {
    return refreshFailed
        ? ConnectionPhase.sessionExpired
        : ConnectionPhase.connectionFailed;
  }

  if (statusCode == 403) {
    switch (upper) {
      case 'DEVICE_REVOKED':
      case 'DEVICE_INACTIVE':
        return ConnectionPhase.accessRevoked;
      case 'SUBSCRIPTION_REQUIRED':
      case 'SUBSCRIPTION_EXPIRED':
        return ConnectionPhase.limitReached;
      default:
        return ConnectionPhase.accessRevoked;
    }
  }

  if (statusCode == 409 || statusCode == 429) {
    return ConnectionPhase.limitReached;
  }

  if (statusCode != null && statusCode >= 500 && statusCode <= 599) {
    return ConnectionPhase.serverUnavailable;
  }

  // Network-level failure, timeout, DNS, no status code at all.
  return ConnectionPhase.connectionFailed;
}
